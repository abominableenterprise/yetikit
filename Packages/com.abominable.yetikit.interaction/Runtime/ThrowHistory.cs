using UnityEngine;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("YetiKit.Interaction.Tests")]

namespace YetiKit.Interaction
{
    /// <summary>One frame of a controller's tracked motion (world space), and where its linear velocity came from.</summary>
    public readonly struct ThrowSample
    {
        public readonly float Time;
        public readonly Vector3 Linear, Angular;
        public readonly string Source;

        public ThrowSample(float time, Vector3 linear, Vector3 angular, string source = null)
        {
            Time = time;
            Linear = linear;
            Angular = angular;
            Source = source;
        }
    }

    /// <summary>
    /// A history of tracked motion. Release uses the peak speed in a recent window rather than the newest
    /// sample, so slowing down while opening the grip does not suppress the throw. Direction averages the
    /// <see cref="TopFrames"/> fastest samples within <see cref="AimCone"/> of the peak; spin comes from the
    /// peak sample. A gap longer than <see cref="HitchGap"/> can anchor the window at the sample before the gap,
    /// provided that sample is still within <see cref="MaxAge"/>.
    /// </summary>
    public sealed class ThrowHistory
    {
        const int MaxSampleRate = 120;
        const float PlayerSmoothingSeconds = 0.04f;
        // The anchor itself, its late window and smoothing lookback, and one post-hitch sample.
        internal const int PlayerCapacity = (int)(LateWindow * MaxSampleRate) +
            (int)(PlayerSmoothingSeconds * MaxSampleRate) + 2;
#if UNITY_EDITOR || DEVELOPMENT_BUILD
        const float MaxSmoothingSeconds = 0.1f;
        // Include the oldest candidate's smoothing lookback, a possible hitch anchor, and boundary samples.
        public const int Capacity = (int)((ThrowTuning.MaxForgiveness + MaxSmoothingSeconds + HitchGap) * MaxSampleRate) + 2;
#else
        public const int Capacity = PlayerCapacity;
#endif
        /// <summary>s back from the release the peak is looked for.</summary>
        public const float PeakWindow = 0.15f;
        /// <summary>s: a late grip release (the button opens as the wrist slows, up to a quarter second after the peak)
        /// still finds the peak: older frames count while speed stays at least <see cref="LateMinSpeed"/>,
        /// contiguous from the normal window. Slow motion before a drop does not extend the window.</summary>
        public const float LateWindow = 0.25f;
        public const float LateMinSpeed = 3f;
        /// <summary>Degrees: scanning back from the release, a frame this far from the peak so far and faster than
        /// <see cref="ReversalSpeed"/> starts an older, reversed stretch: the wind-up before the throw, or the throw
        /// itself when the newer frames were only its follow-through. The older stretch's fastest frame (up to its own
        /// reversal or the window's limit) decides: slower than (or as fast as) the peak so far, it was the wind-up and
        /// the window ends at the reversal. A faster older stretch can become the peak if the newer frames
        /// qualify as follow-through.</summary>
        public const float Reversal = 90f;
        public const float ReversalSpeed = 1.5f;
        /// <summary>An older, reversed stretch is promoted to the throw (the newer frames its follow-through) only when
        /// the newer stretch's peak is below this fraction of the older one's: a follow-through is much slower than the
        /// throw. A newer stretch about as fast as its wind-up keeps priority over that wind-up.</summary>
        public const float FollowThroughRatio = 0.5f;
        /// <summary>Degrees: the ratio test is for a straight back-and-forth (a wind-up, ~180°). An older stretch within
        /// this angle of the newer peak can be a curve into follow-through: a faster older stretch is enough.</summary>
        public const float WindUpAngle = 135f;
        /// <summary>Hand frames: a frame is a peak candidate only with this many frames in its smoothing window (a
        /// smaller window cannot trim the extremes). With no sufficiently sampled frame, release treats the hand
        /// as still.</summary>
        public const int MinSmoothFrames = 3;
        public const int TopFrames = 3;
        public const float MaxAge = 0.25f;
        /// <summary>A gap this long (s) before the newest frame is a hitch, not a frame (two frames at 72 Hz are 28 ms).</summary>
        public const float HitchGap = 0.05f;
        /// <summary>Degrees: only frames within this of the peak's direction aim the throw.</summary>
        public const float AimCone = 60f;

        readonly ThrowSample[] samples = new ThrowSample[Capacity];
        readonly int[] top = new int[TopFrames];
        readonly Vector3[] smoothed = new Vector3[Capacity];
        readonly Vector3[] smoothedSpin = new Vector3[Capacity];
        readonly bool[] sparse = new bool[Capacity];
        readonly bool[] trajectory = new bool[Capacity];
        readonly uint[] segments = new uint[Capacity];
        int next, count, continuousFrames;
        uint segment;
        bool needsMotion;

        public int Count => count;
        /// <summary>The fastest raw (unsmoothed) frame of the last release's window, m/s (the throw log's raw peak).</summary>
        public float RawPeak { get; private set; }
        public Vector3 RawDirection { get; private set; }

        /// <summary>Newest-first index of a selected sample; -1 denotes carried/synthetic motion.</summary>
        public int SampleIndex(ThrowSample sample)
        {
            for (var i = 0; i < count; i++)
                if (Mathf.Abs(Back(i).Time - sample.Time) < 1e-5f) return i;
            return -1;
        }

        /// <summary>The newest sample (default when empty).</summary>
        public ThrowSample Latest => count > 0 ? samples[(next - 1 + Capacity) % Capacity] : default;
        public ThrowSample Previous => count > 1 ? Back(1) : default;

        /// <summary>Reversal evidence for the raw release. The immediate predecessor survives a hitch. Across a pause,
        /// keep an isolated outward step (a possible tracking jump), but not an established swing that has stopped.</summary>
        public ThrowSample PreviousMotion
        {
            get
            {
                for (var i = 1; i < count && Segment(i) == segment; i++)
                {
                    var sample = Back(i);
                    if (Latest.Time - sample.Time > (i == 1 ? MaxAge : ThrowTuning.Forgiveness)) break;
                    if (sample.Linear.sqrMagnitude < HandReleaseVelocity.StillSpeed * HandReleaseVelocity.StillSpeed) continue;
                    // A speed-supported swing that has stopped no longer argues against a new release-frame
                    // flick. Continuity alone must not retire an isolated speed spike after slow motion.
                    if (i > 1 && EstablishedMotion(i)) return default;
                    return sample;
                }
                return default;
            }
        }

        /// <summary>The newest position is supported by speed-consistent motion, not only sample continuity.</summary>
        public bool LatestMotionEstablished => count > 0 && Segment(0) == segment && EstablishedMotion(0, true);

        bool EstablishedMotion(int at, bool consistentSpeed = false)
        {
            if (at + MinSmoothFrames > count || !SameSegment(at, at + MinSmoothFrames - 1)) return false;
            var direction = Back(at).Linear;
            var supportedSpeedSquared = direction.sqrMagnitude;
            // A displaced baseline needs independent support for the fastest step, not slow samples
            // that merely point the same way as an isolated accepted jump.
            if (consistentSpeed)
                for (var i = at + 1; i < at + MinSmoothFrames; i++)
                    supportedSpeedSquared = Mathf.Max(supportedSpeedSquared, Back(i).Linear.sqrMagnitude);
            var minSpeedSquared = Mathf.Max(HandReleaseVelocity.StillSpeed * HandReleaseVelocity.StillSpeed,
                supportedSpeedSquared * 0.25f);
            for (var i = at; i < at + MinSmoothFrames; i++)
            {
                var sample = Back(i);
                if (sample.Linear.sqrMagnitude < minSpeedSquared ||
                    Vector3.Dot(direction, sample.Linear) <= 0f) return false;
                if (i > at && Back(i - 1).Time - sample.Time > HitchGap) return false;
            }
            return true;
        }

        /// <summary>Can the newest raw frame be promoted? A hand needs an established trajectory since its last
        /// discontinuity, not three samples inside the smoothing window: elapsed-frame motion across a hitch is still
        /// motion. Clear/reseed, a discarded tracking snap, or a stale baseline require fresh evidence first.
        /// Speed and out-and-back plausibility are checked separately by HandReleaseVelocity.ReleaseFrame.
        /// Zero smoothing stays unfiltered.</summary>
        public bool LatestCanPromote(float smoothing) =>
            count > 0 && (smoothing <= 0f || continuousFrames >= MinSmoothFrames);

        /// <summary>The position baseline jumped without a usable velocity (for example a discarded tracking snap).
        /// Keep the older smoothed throw, but never use its frames to support motion on the new baseline.
        /// Stationary frames (including tracking jitter) do not establish a trajectory.</summary>
        public void Discontinuity()
        {
            // Repeated discontinuities before the next sample only need one boundary.
            if (count > 0 && Segment(0) == segment) segment++;
            continuousFrames = 0;
            needsMotion = true;
        }

        public void Add(ThrowSample s)
        {
            if (count > 0)
            {
                var elapsed = s.Time - Latest.Time;
                if (elapsed <= 0f) Clear();
                if (elapsed <= 0f || elapsed > MaxAge) Discontinuity();
            }
            continuousFrames = needsMotion && s.Linear.sqrMagnitude < HandReleaseVelocity.StillSpeed * HandReleaseVelocity.StillSpeed
                ? 0 : Mathf.Min(continuousFrames + 1, Capacity);
            if (continuousFrames >= MinSmoothFrames) needsMotion = false;
            trajectory[next] = continuousFrames >= MinSmoothFrames;
            segments[next] = segment;
            samples[next] = s;
            next = (next + 1) % Capacity;
            if (count < Capacity) count++;
        }

        public void Clear()
        {
            next = count = continuousFrames = 0;
            needsMotion = false;
            segment = 0;
            RawPeak = 0f;
            RawDirection = Vector3.zero;
        }

        int Slot(int back) => (next - 1 - back + Capacity) % Capacity;
        ThrowSample Back(int i) => samples[Slot(i)];
        uint Segment(int i) => segments[Slot(i)];
        bool SameSegment(int a, int b) => Segment(a) == Segment(b);
        bool Fresh(float now) => count > 0 && now >= Latest.Time && now - Latest.Time <= MaxAge;

        /// <summary>The release sample: the peak speed in the window, aimed along the average of the fastest frames;
        /// false when nothing recent was recorded.</summary>
        public bool Release(float now, out ThrowSample peak) => Release(now, out peak, 0f);

        /// <summary>
        /// The time the peak window is measured back from: the newest frame, or, when it came after a hitch
        /// (<see cref="HitchGap"/>) and the frame before it is still fresh (<see cref="MaxAge"/>), that frame.
        /// </summary>
        float WindowEnd(float now)
        {
            var newest = Back(0).Time;
            if (count < 2) return newest;
            var before = Back(1).Time;
            return newest - before > HitchGap && now - before <= MaxAge ? before : newest;
        }

        /// <summary>
        /// <see cref="Release(float, out ThrowSample)"/> with each frame's linear velocity first averaged over the
        /// <paramref name="smoothing"/> s up to it (0: raw frames, the controller path). A tracked hand's palm velocity
        /// is a noisy frame delta: a short window keeps one jittery frame from setting the throw's speed.
        /// </summary>
        public bool Release(float now, out ThrowSample peak, float smoothing)
        {
            peak = default;
            if (!Fresh(now)) return false;
            var m = Window(WindowEnd(now), smoothing, out var best);
            RawPeak = 0f;
            RawDirection = Vector3.zero;
            for (var i = 0; i < m; i++)
                if (Back(i).Linear.magnitude > RawPeak)
                {
                    RawPeak = Back(i).Linear.magnitude;
                    RawDirection = Back(i).Linear.normalized;
                }
            if (best < 0)
            {
                // A hand window with no frame dense enough to trust (a dropped frame around a tracking jump): a still hand.
                peak = new ThrowSample(Back(0).Time, Vector3.zero, Vector3.zero, Back(0).Source);
                return true;
            }
            var fastest = Back(best);
            var fastestLinear = smoothed[best];
            // The fastest frames aimed like the peak (within AimCone), fastest first; the peak itself is always first.
            var cos = Mathf.Cos(AimCone * Mathf.Deg2Rad);
            var n = 0;
            for (var i = 0; i < m; i++)
            {
                var v = smoothed[i];
                if (sparse[i]) continue;
                if (i != best && Vector3.Dot(v, fastestLinear) < cos * v.magnitude * fastestLinear.magnitude) continue;
                var speed = v.sqrMagnitude;
                var at = n < TopFrames ? n : TopFrames;
                while (at > 0 && smoothed[top[at - 1]].sqrMagnitude < speed) at--;
                if (at >= TopFrames) continue;
                for (var k = Mathf.Min(n, TopFrames - 1); k > at; k--) top[k] = top[k - 1];
                top[at] = i;
                if (n < TopFrames) n++;
            }
            var sum = Vector3.zero;
            for (var k = 0; k < n; k++) sum += smoothed[top[k]];
            var dir = sum.sqrMagnitude > 1e-8f ? sum.normalized : fastestLinear.normalized;
            peak = new ThrowSample(fastest.Time, dir * fastestLinear.magnitude, smoothedSpin[best], fastest.Source);
            return true;
        }

        /// <summary>Recover a supported palm apex without the per-axis median flattening a curved swing.
        /// Keep the existing window's wind-up/follow-through classification. Two adjacent, aligned near-peak
        /// samples must both have plausible acceleration; an isolated tracking step is never promoted.</summary>
        public bool HandSwingPeak(float now, float smoothing, out ThrowSample peak) =>
            HandSwingPeak(now, smoothing, out peak, out _);

        /// <summary>Also expose the oldest time retained by validated turn classification, so release
        /// selection can distinguish an excluded wind-up from an unsupported flick inside this swing.</summary>
        public bool HandSwingPeak(float now, float smoothing, out ThrowSample peak, out float windowStart)
        {
            peak = default;
            windowStart = float.NegativeInfinity;
            if (count < 3 || !Fresh(now)) return false;
            // Supported raw segments avoid median lag at the apex. Else retain smoothed turn
            // evidence: skipping a whole abrupt forward flick could expose its older wind-up.
            var m = Window(WindowEnd(now), smoothing, out _, validatedHandTurns: true);
            if (m > 0) windowStart = Back(m - 1).Time;
            for (var i = 0; i < m; i++)
                if (Back(i).Linear.magnitude > RawPeak)
                {
                    RawPeak = Back(i).Linear.magnitude;
                    RawDirection = Back(i).Linear.normalized;
                }
            var bestSpeed = 0f;
            for (var i = 0; i < m; i++)
            {
                var candidate = Back(i);
                // Unlike the controller hitch path, hand forgiveness ends at the actual release.
                if (now - candidate.Time > ThrowTuning.Forgiveness + 1e-4f) continue;
                var speed = candidate.Linear.magnitude;
                if (speed <= bestSpeed || !SupportedHandFrame(i, m)) continue;
                bestSpeed = speed;
                // Use the apex segment's direction, not the slow tail's average direction.
                Smoothed(i, smoothing, out _, out var spin, out _);
                peak = new ThrowSample(candidate.Time, candidate.Linear, spin, candidate.Source);
            }
            return bestSpeed > 0f;
        }

        /// <summary>Whether the normal selector's source frame belongs to a supported palm swing.</summary>
        public bool SupportedHandSample(float time)
        {
            for (var i = 0; i < count; i++)
                if (Back(i).Time == time) return SupportedHandFrame(i, count);
            return false;
        }

        /// <summary>Whether a selected frame could be an older supported wind-up. A trajectory
        /// accelerating from observed rest is a complete swing, not just evidence of a wind-up.</summary>
        public bool SupportedHandWindup(float time)
        {
            for (var i = 0; i < count; i++)
            {
                if (Back(i).Time != time) continue;
                if (!SupportedHandFrame(i, count)) return false;
                var olderPeak = Back(i).Linear.magnitude;
                for (var j = i + 1; j < count && SameSegment(i, j) && time - Back(j).Time <= ThrowTuning.Forgiveness; j++)
                {
                    var before = Back(j).Linear;
                    if (before.magnitude <= HandReleaseVelocity.StillSpeed)
                    {
                        // Rest or a sustained slow tail completes the newer supported swing.
                        // Require three settled, aligned frames and comparable supported motion.
                        // Allow 1 m/s estimation error at the ratio boundary: a gentler toss must
                        // not lose to its wind-up over a sub-m/s difference. Retain the strength
                        // guard so settling reverse recoil cannot become a new throw.
                        // Only validated motion supplies either speed; raw spikes are diagnostic.
                        if (SameSegment(0, i) && Latest.Linear.magnitude <= HandReleaseVelocity.StillSpeed) return true;
                        for (var k = MinSmoothFrames; k < i; k++)
                        {
                            var swing = Back(k).Linear;
                            if (!SameSegment(0, k) || !SameSegment(k, i) ||
                                !SupportedHandFrame(k, count) || Vector3.Dot(swing, Back(i).Linear) >= 0f ||
                                swing.magnitude + 1f < .6f * olderPeak) continue;
                            var settled = true;
                            for (var tail = 0; tail < MinSmoothFrames; tail++)
                                if (Back(tail).Linear.magnitude >= .4f * swing.magnitude ||
                                    Vector3.Dot(Back(tail).Linear, swing) <= 0f ||
                                    Back(tail).Time - Back(tail + 1).Time > HitchGap) settled = false;
                            if (settled) return true;
                        }
                        return false;
                    }
                    if (Vector3.Dot(before, Back(i).Linear) < 0f) break;
                    if (SupportedHandFrame(j, count)) olderPeak = Mathf.Max(olderPeak, before.magnitude);
                }
                return true;
            }
            return false;
        }

        // Use the same evidence for raw turn classification and apex selection. Unsupported frames
        // retain their smoothed turn evidence, but cannot introduce a raw tracking spike as a peak.
        bool SupportedHandFrame(int i, int limit)
        {
            var candidate = Back(i);
            var speed = candidate.Linear.magnitude;
            if (candidate.Source != ThrowSources.HandPalm ||
                !trajectory[Slot(i)] || !PlausibleAcceleration(i) ||
                speed > ThrowSources.MaxHandStep) return false;
            for (var j = Mathf.Max(0, i - 1); j <= Mathf.Min(limit - 1, i + 1); j++)
            {
                if (j == i || !SameSegment(i, j) || !PlausibleAcceleration(j)) continue;
                var neighbour = Back(j);
                var neighbourSpeed = neighbour.Linear.magnitude;
                if (neighbour.Source != ThrowSources.HandPalm ||
                    Mathf.Abs(candidate.Time - neighbour.Time) > HitchGap ||
                    neighbourSpeed < speed * 0.75f || neighbourSpeed > ThrowSources.MaxHandStep) continue;
                if (Vector3.Dot(candidate.Linear, neighbour.Linear) >= 0.5f * speed * neighbourSpeed) return true;
            }
            return false;
        }

        // 500 m/s² permits a hard 0–12 m/s swing over ~25 ms, but rejects a tracking jump.
        // Validate the supporting frame too: two frames on a jumped baseline are not a real apex.
        bool PlausibleAcceleration(int i)
        {
            if (i + 1 >= count || !SameSegment(i, i + 1)) return false;
            var sample = Back(i);
            var before = Back(i + 1);
            var dt = sample.Time - before.Time;
            return dt > 1e-4f && dt <= HitchGap &&
                (sample.Linear - before.Linear).sqrMagnitude <= 500f * 500f * dt * dt;
        }

        /// <summary>
        /// The frames of the release window, newest first (the newest is always in), smoothed into <see cref="smoothed"/>;
        /// returns their count and the fastest candidate (<paramref name="best"/>, -1: none). Scanning back, a reversal
        /// (<see cref="Reversal"/>) opens an older stretch: it ends the window unless that stretch turns out faster than
        /// the peak so far (then the newer frames were the follow-through).
        /// </summary>
        int Window(float end, float smoothing, out int best, bool validatedHandTurns = false)
        {
            var reverse = Mathf.Cos(Reversal * Mathf.Deg2Rad);
            best = -1;
            var cut = -1;     // where the pending older, reversed stretch starts (-1: none)
            var cutPeak = -1; // its fastest frame so far
            var flipped = false; // the newer frames were already found to be a follow-through: the next reversal is the wind-up
            var classification = -1; // direction defining that turn boundary; independent of its retained peak
            var m = 0;
            for (var i = 0; i < count; i++, m++)
            {
                var age = end - Back(i).Time;
                if (i > 0 && age > Mathf.Max(LateWindow, ThrowTuning.Forgiveness) + 1e-4f) break;
                if (i > 0 && age > ThrowTuning.Forgiveness + 1e-4f && Back(i).Linear.sqrMagnitude < LateMinSpeed * LateMinSpeed) break;
                var full = Smoothed(i, smoothing, out smoothed[i], out smoothedSpin[i], out var n);
                if (i > 0 && !full) break;
                sparse[i] = smoothing > 0f && n < MinSmoothFrames;
                if (sparse[i]) continue;
                if (validatedHandTurns && SupportedHandFrame(i, count)) smoothed[i] = Back(i).Linear;
                var v = smoothed[i];
                if (best < 0) { best = i; continue; }
                if (cut < 0)
                {
                    if (Reversed(v, smoothed[classification >= 0 ? classification : best], reverse))
                    {
                        if (flipped) return i; // only one follow-through after a throw: this is the wind-up
                        if (FollowedThrough(smoothed[best], v)) { best = classification = i; flipped = true; } // the throw at once
                        else cut = cutPeak = i;
                    }
                    else if (v.sqrMagnitude > smoothed[best].sqrMagnitude) best = classification = i;
                    continue;
                }
                // Inside the older stretch: reversed again before it got faster than the peak, it was the wind-up.
                if (Reversed(v, smoothed[cutPeak], reverse)) return cut;
                if (v.sqrMagnitude > smoothed[cutPeak].sqrMagnitude) cutPeak = i;
                // A slower frame can classify the whole pending stretch as a turn. Keep that stretch's
                // recorded peak, not merely the frame that supplied the classification evidence.
                if (FollowedThrough(smoothed[best], v)) { best = cutPeak; classification = i; cut = -1; flipped = true; }
            }
            return cut >= 0 ? cut : m;
        }

        /// <summary>Were the newer frames (peaking at <paramref name="newer"/>) only the follow-through of an older
        /// stretch reaching <paramref name="older"/>? (<see cref="FollowThroughRatio"/>)</summary>
        static bool FollowedThrough(Vector3 newer, Vector3 older) =>
            newer.sqrMagnitude < FollowThroughRatio * FollowThroughRatio * older.sqrMagnitude ||
            (older.sqrMagnitude > newer.sqrMagnitude &&
             Vector3.Dot(newer, older) > Mathf.Cos(WindUpAngle * Mathf.Deg2Rad) * newer.magnitude * older.magnitude);

        static bool Reversed(Vector3 v, Vector3 from, float cos) =>
            v.sqrMagnitude > ReversalSpeed * ReversalSpeed && Vector3.Dot(v, from) < cos * v.magnitude * from.magnitude;

        /// <summary>
        /// Frame <paramref name="i"/> back, smoothed over the <paramref name="window"/> s up to it (0: the raw frame, the
        /// controller path). Hand frames: a trimmed mean per axis, each component's mean without its highest and lowest
        /// value. A tracked palm's glitches are single frames: a spike out and back (one frame out, the next back, which
        /// are each other's opposite) or a re-fit that jumps once; neither sets the peak or drags its neighbours, and a
        /// cancelling pair drops out together (trimming by speed dropped only one of them, leaving the other as motion). With
        /// the default 3-frame window this is the per-axis median, which keeps a real swing's peak. Returns false when the
        /// history starts inside the window with fewer than <see cref="MinSmoothFrames"/> frames. The spin is smoothed the same way
        /// on its own (the wrist's fitted rotation jumps when the fingers open at the release; ω × r would turn that
        /// into speed). <paramref name="n"/>: the frames in its window.
        /// </summary>
        bool Smoothed(int i, float window, out Vector3 linear, out Vector3 angular, out int n)
        {
            var s = Back(i);
            linear = s.Linear;
            angular = s.Angular;
            n = 1;
            if (window <= 0f) return true;
            n = 0;
            for (var j = i; j < count; j++, n++)
                if (j > i && (!SameSegment(i, j) || s.Time - Back(j).Time > window - 1e-4f)) break;
            linear = Trimmed(i, n, false);
            angular = Trimmed(i, n, true);
            return n >= MinSmoothFrames || i + n < count;
        }

        /// <summary>The per-axis trimmed mean of the linear (or angular) velocity of frames i .. i+n-1 back: with 3 or
        /// more frames each component's highest and lowest value are left out.</summary>
        Vector3 Trimmed(int i, int n, bool spin)
        {
            var sum = Vector3.zero;
            var hi = Value(i, spin);
            var lo = hi;
            for (var k = 0; k < n; k++)
            {
                var v = Value(i + k, spin);
                sum += v;
                hi = Vector3.Max(hi, v);
                lo = Vector3.Min(lo, v);
            }
            if (n < 3) return sum / n;
            return (sum - hi - lo) / (n - 2);
        }

        Vector3 Value(int back, bool spin) => spin ? Back(back).Angular : Back(back).Linear;
    }
}
