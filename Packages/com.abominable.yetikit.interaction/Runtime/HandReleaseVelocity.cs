using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>
    /// Selects a tracked hand's release velocity from its palm history. Smoothing can suppress a genuine
    /// release-frame flick, so a fast raw frame can replace the smoothed peak if it is not a tracking snap or
    /// the return leg of an out-and-back glitch. Preserves recent motion across a brief tracking loss, while
    /// a hand that was already still remains a drop. Launch caps are applied separately by <see cref="PropThrow"/>.
    /// </summary>
    public sealed class HandReleaseVelocity
    {
        /// <summary>Seconds a velocity read at tracking loss stays usable.</summary>
        public const float CarryTime = 0.3f;
        /// <summary>m/s below which the hand at a loss was still: the prop drops.</summary>
        public const float StillSpeed = 0.5f;
        /// <summary>s a reacquired hand keeps the carried velocity: its new history needs about this long to show the throw
        /// itself; a hand that came back and then held still past it drops.</summary>
        public const float ReacquireTime = 0.1f;

        ThrowSample carry;
        float carryAt = float.NegativeInfinity;
        float carryUntil = float.NegativeInfinity;
        float carryEnd = float.NegativeInfinity; // the carry's own lifetime (CarryTime from its loss); a reacquire only shortens carryUntil

        /// <summary>The velocity kept from the last tracking loss, when there is one younger than <see cref="CarryTime"/> at
        /// <paramref name="now"/>.</summary>
        public bool Carried(float now, out ThrowSample sample)
        {
            sample = carry;
            return now >= carryAt && now <= carryUntil;
        }

        /// <summary>Tracking was just lost at <paramref name="now"/>: keep the palm's release velocity from the frames
        /// before it (an older carry still in time and faster stays: tracking flickering off, on and off again, and gets its
        /// own <see cref="CarryTime"/> back, which a reacquire had cut to <see cref="ReacquireTime"/>, never more).</summary>
        public void TrackingLost(float now, ThrowHistory history, float smoothing, Vector3? headForward = null)
        {
            var have = Choose(now, history, smoothing, out var at, headForward);
            if (have && at.Linear.magnitude < StillSpeed) at = new ThrowSample(at.Time, Vector3.zero, Vector3.zero, at.Source);
            if (Carried(now, out var old) && (!have || old.Linear.sqrMagnitude >= at.Linear.sqrMagnitude))
            {
                carryUntil = carryEnd;
                return;
            }
            if (!have) return;
            carry = at;
            carryAt = now;
            carryUntil = carryEnd = now + CarryTime;
        }

        /// <summary>The hand is tracked again at <paramref name="now"/>: the carry lasts at most
        /// <see cref="ReacquireTime"/> s more.</summary>
        public void TrackingBack(float now) => carryUntil = Mathf.Min(carryUntil, now + ReacquireTime);

        /// <summary>Forget the carried velocity (a controller took over).</summary>
        public void Clear() => carryAt = carryUntil = carryEnd = float.NegativeInfinity;

        /// <summary>
        /// The hand's release sample at <paramref name="now"/>: the history's smoothed peak, the release frame when it is
        /// faster (<see cref="ReleaseFrame"/>), and the velocity carried over a tracking loss when that is faster still.
        /// False when there is nothing recent at all.
        /// </summary>
        public bool Release(float now, ThrowHistory history, float smoothing, out ThrowSample sample, Vector3? headForward = null)
        {
            var have = Choose(now, history, smoothing, out sample, headForward);
            if (!Carried(now, out var kept)) return have;
            if (have && sample.Linear.sqrMagnitude >= kept.Linear.sqrMagnitude) return true;
            sample = new ThrowSample(now, kept.Linear, kept.Angular, kept.Source);
            return true;
        }

        /// <summary>The smoothed peak, or the release frame when that is faster (<see cref="ReleaseFrame"/>).</summary>
        public static bool Choose(float now, ThrowHistory history, float smoothing, out ThrowSample sample, Vector3? headForward = null)
        {
            if (!history.Release(now, out sample, smoothing)) return false;
            var swing = default(ThrowSample);
            var swingStart = float.NegativeInfinity;
            var haveSwing = history.Latest.Source == ThrowSources.HandPalm &&
                history.HandSwingPeak(now, smoothing, out swing, out swingStart);
            // Opposing supported swings are ambiguous in palm motion alone. Use the body's
            // horizontal facing only to pick a candidate, never to aim or reshape its velocity.
            var normalTime = sample.Time;
            var bodyChoice = sample;
            var preferSwing = false;
            var bodyDecides = headForward.HasValue && haveSwing && Vector3.Dot(sample.Linear, swing.Linear) < 0f &&
                history.SupportedHandSample(sample.Time) &&
                PreferByFacing(sample.Linear, swing.Linear, headForward.Value, out preferSwing);
            if (bodyDecides && preferSwing) bodyChoice = swing;
            // Exclusion alone is not wind-up evidence: median lag can also exclude an abrupt
            // forward flick. Only dismiss a supported wind-up, not a swing accelerated from rest.
            if (haveSwing && (swing.Linear.sqrMagnitude > sample.Linear.sqrMagnitude ||
                (((sample.Time < swingStart && history.SupportedHandWindup(sample.Time)) ||
                  swing.Linear.sqrMagnitude >= .75f * .75f * sample.Linear.sqrMagnitude) &&
                 Vector3.Dot(sample.Linear, swing.Linear) < 0f))) sample = swing;
            if (now - history.Latest.Time <= ThrowHistory.HitchGap && history.LatestCanPromote(smoothing))
                sample = ReleaseFrame(sample, history.Latest, history.PreviousMotion);
            // Only a validated apex can establish a collapse; RawPeak includes rejected tracking spikes.
            // Never let a release-frame reversal replace that established swing's direction.
            if (haveSwing && (sample.Linear.magnitude < swing.Linear.magnitude * .4f ||
                (sample.Linear.magnitude <= swing.Linear.magnitude &&
                 Vector3.Dot(sample.Linear, swing.Linear) < 0f))) sample = swing;
            // Recovery must not undo a supported body-relative decision. A separately promoted
            // release flick is a third candidate, not one of the two supported swings compared.
            if (bodyDecides && (sample.Time == normalTime || sample.Time == swing.Time)) sample = bodyChoice;
            return true;
        }

        static bool PreferByFacing(Vector3 normal, Vector3 swing, Vector3 headForward, out bool preferSwing)
        {
            var facing = Vector3.ProjectOnPlane(headForward, Vector3.up);
            var a = Vector3.ProjectOnPlane(normal, Vector3.up);
            var b = Vector3.ProjectOnPlane(swing, Vector3.up);
            preferSwing = false;
            // No horizontal evidence (including a vertical throw): retain the legacy fallback.
            // A near-vertical swing's tiny horizontal tracking wobble is not body evidence.
            // Require at least 20% horizontal speed for both candidates before normalizing.
            if (facing.sqrMagnitude < 1e-6f || a.sqrMagnitude < 1e-6f || b.sqrMagnitude < 1e-6f ||
                a.sqrMagnitude < .04f * normal.sqrMagnitude || b.sqrMagnitude < .04f * swing.sqrMagnitude) return false;
            var difference = Vector3.Dot(b.normalized, facing.normalized) - Vector3.Dot(a.normalized, facing.normalized);
            preferSwing = difference > 0f;
            return Mathf.Abs(difference) >= .2f;
        }

        /// <summary>
        /// <paramref name="peak"/>, or the raw <paramref name="newest"/> frame (with the peak's spin) when it is faster and
        /// can be trusted: a hand frame, not a snap (<see cref="ThrowSources.MaxHandStep"/>), and not reversed against
        /// a fast <paramref name="previous"/> frame (the "back" of an out-and-back glitch, faster than
        /// <see cref="ThrowHistory.ReversalSpeed"/>).
        /// </summary>
        public static ThrowSample ReleaseFrame(ThrowSample peak, ThrowSample newest, ThrowSample previous)
        {
            if (newest.Source != ThrowSources.HandPalm) return peak;
            var speed = newest.Linear.sqrMagnitude;
            if (speed <= peak.Linear.sqrMagnitude) return peak;
            if (speed > ThrowSources.MaxHandStep * ThrowSources.MaxHandStep) return peak;
            var back = previous.Linear;
            if (back.sqrMagnitude > ThrowHistory.ReversalSpeed * ThrowHistory.ReversalSpeed && Vector3.Dot(back, newest.Linear) < 0f)
                return peak;
            return new ThrowSample(newest.Time, newest.Linear, peak.Angular, newest.Source);
        }
    }
}
