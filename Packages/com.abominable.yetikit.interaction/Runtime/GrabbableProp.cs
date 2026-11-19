using YetiKit.Hands;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;

namespace YetiKit.Interaction
{
    /// <summary>
    /// A loose prop the player can pick up and throw (the <see cref="XRGrabInteractable"/> does the grabbing). This
    /// component starts it asleep at its home spot, sends it home when lost or left lying (<see cref="PropRespawnRules"/>),
    /// and reports the first eligible impact per throw (<see cref="IThrownHitSink"/>).
    /// While held and for a moment after (<see cref="HeldLayer"/>) it uses the optional HeldProp layer and ignores
    /// nearby loose props (<see cref="HeldNeighbours"/>) and the prop held by another hand (<see cref="HeldPairs"/>).
    /// </summary>
    [RequireComponent(typeof(Rigidbody), typeof(PropGrabInteractable))]
    public sealed class GrabbableProp : MonoBehaviour, IGripSource
    {
        // Safety ceilings for all motion sources, including collision/depenetration after release.
        // Linear stays above the legitimate assisted controller throw maximum (34.5 m/s).
        public const float MaxLinearSpeed = 35f;
        public const float MaxAngularSpeed = PropThrow.MaxAngularSpeed; // rad/s, preserve the existing 20 rad/s ceiling

        const float CheckInterval = 0.5f;
        const float RestSpeed = 0.05f;

        [Tooltip("How the hand holds this prop.")]
        public GripSpec grip = new GripSpec(GripKind.Cylinder, Vector3.up, Vector3.forward, Vector3.zero, 0.03f);
        [Tooltip("Turn the left-hand grip 180 degrees about its axis.")]
        public bool handed;

        [Tooltip("Turn the left-hand grip 180 degrees about its palm normal.")]
        public bool faceToWrist;

        /// <summary>Optional per-input-mode runtime data. Missing entries retain the authored grip.</summary>
        public GripProfiles gripProfiles = new GripProfiles();

        public string GripIdFor(HandMode mode) => gripProfiles?.For(mode)?.id ?? string.Empty;

        /// <summary>Resolve the mode override before applying the existing left-hand rules.</summary>
        public GripSpec GripFor(bool rightHand, HandMode mode) =>
            ForHand(gripProfiles?.For(mode)?.spec ?? grip, rightHand);

        /// <summary>
        /// The grip for the <paramref name="rightHand"/> or left hand. GripPlacement builds a proper rotation from the
        /// mirrored left glove's back and thumb, so a prop's +Z that runs along the right hand's fingers runs back
        /// toward the left wrist (and the reverse); a <see cref="handed"/> prop flips its palm side there, turning it about
        /// its axis; a <see cref="faceToWrist"/> prop flips its axis, turning it about the palm normal.
        /// </summary>
        public GripSpec GripFor(bool rightHand) => ForHand(grip, rightHand);

        GripSpec ForHand(GripSpec g, bool rightHand)
        {
            if (rightHand || !handed && !faceToWrist) return g;
            if (handed) g.palm = -g.palm;
            if (faceToWrist) g.axis = -g.axis;
            return g;
        }
        [Tooltip("Enable distance, idle and area respawn. Loose props still recover from falls.")]
        public bool respawns = true;

        /// <summary>Optional owner handler used in place of the default return home.</summary>
        public event System.Action ReturnHome;
        /// <summary>Optional owner handler for falls, used in place of the normal return-home path.</summary>
        public event System.Action<GrabbableProp> RecoverFromFall;
        [Tooltip("Where this prop may rest without idle respawn (world bounds; size zero: none).")]
        public Bounds homeArea;
        public PropRespawnSettings RespawnSettings { get; set; } = PropRespawnSettings.Default;

        /// <summary>Raw contacts in flight, including contacts that do not count as hits.</summary>
        public event System.Action<GrabbableProp, Collider> LaunchedPropContacted;
        /// <summary>Register a hit sink for this prop, or pass null to unregister it.</summary>
        public IThrownHitSink HitSink { get; set; }
        bool inFlight;

        Rigidbody body;
        Vector3 velocityBefore; // m/s: FixedUpdate's sample, valid only until the first contact (enter or stay)
        HeldLayer layer;
        HeldNeighbours neighbours;
        HeldPairs pairs;
        PropGrabInteractable grab;
        Vector3 homePosition;
        Quaternion homeRotation;
        float idle, outOfArea, nextCheck;
        readonly PropHitFilter hits = new PropHitFilter();

        public Vector3 Home => homePosition;
        /// <summary>Changes when an owner/recovery resets motion. Sampled observers must not sweep across that reset.</summary>
        public uint MotionRevision { get; private set; }
        /// <summary>Stuck in something: no respawn or idle clock while stuck; counts as away from home.</summary>
        public bool Stuck { get; private set; }
        /// <summary>Away from its home spot for the respawn rules (stuck counts as away).</summary>
        public bool Away => PropRespawnRules.Away(transform.position, homePosition, Stuck, RespawnSettings);

        /// <summary>Stuck in (or out of) something that holds it kinematically.</summary>
        public void SetStuck(bool stuck)
        {
            Stuck = stuck;
            idle = outOfArea = 0f;
        }
        public bool Held => grab && grab.isSelected;

        /// <summary>The neighbours this prop ignores since its last grab (tests).</summary>
        public HeldNeighbours Neighbours => neighbours;

        /// <summary>The props held in the other hand this one ignores since its grab (tests).</summary>
        public HeldPairs Pairs => pairs;

        /// <summary>Its physics body.</summary>
        public Rigidbody Body => body ? body : body = GetComponent<Rigidbody>();

        void Awake()
        {
            body = GetComponent<Rigidbody>();
            body.maxLinearVelocity = MaxLinearSpeed;
            body.maxAngularVelocity = MaxAngularSpeed;
            grab = GetComponent<PropGrabInteractable>();
            homePosition = transform.position;
            homeRotation = transform.rotation;
            nextCheck = Random.value * CheckInterval; // spread the checks over frames
            var heldLayer = LayerMask.NameToLayer(HeldLayer.LayerName);
            layer = new HeldLayer(gameObject.layer, heldLayer >= 0 ? heldLayer : gameObject.layer);
            neighbours = new HeldNeighbours(GetComponent<Collider>());
            pairs = new HeldPairs(HeldPairs.SolidOf(body), () => Held, () => layer.Active(Time.time));
            if (!grab)
            {
                Debug.LogError("GrabbableProp requires PropGrabInteractable; replace the incompatible XRGrabInteractable.", this);
                enabled = false;
            }
        }

        void OnEnable()
        {
            if (!grab) { enabled = false; return; }
            pairs.Enable();
            if (grab.isSelected) OnGrabbed(null);
            grab.selectEntered.AddListener(OnGrabbed);
            grab.selectExited.AddListener(OnReleased);
            grab.LaunchedFromHand += OnLaunched;
            grab.Released += OnReleaseSettled;
        }

        void OnDisable()
        {
            if (layer == null) return;
            neighbours.Clear();
            pairs.Disable();
            hits.Reset();
            inFlight = false;
            layer.Release(float.NegativeInfinity);
            SetLayer(layer.Layer(Time.time));
            if (!grab) return;
            grab.selectEntered.RemoveListener(OnGrabbed);
            grab.selectExited.RemoveListener(OnReleased);
            grab.LaunchedFromHand -= OnLaunched;
            grab.Released -= OnReleaseSettled;
        }

        void Start() => body.Sleep(); // placed at rest: no settling jitter at load

        void OnGrabbed(SelectEnterEventArgs _)
        {
            hits.Reset();
            inFlight = false;
            layer.Grab();
            SetLayer(layer.Layer(Time.time));
            neighbours.Grab(body.worldCenterOfMass);
            pairs.Grab();
        }

        void OnReleased(SelectExitEventArgs _)
        {
            if (grab.isSelected) return; // hand-to-hand pass
            if (!grab.PendingLateRelease) layer.Release(Time.time);
            idle = 0f;
        }

        void OnLaunched()
        {
            if (grab.Launched) BeginFlight(Time.time);
        }

        void OnReleaseSettled(PropGrabInteractable _, Transform hand)
        {
            if (Held) return;
            layer.Release(Time.time);
            idle = 0f;
        }

        void SetLayer(int l)
        {
            if (gameObject.layer == l) return;
            foreach (var t in GetComponentsInChildren<Transform>(true)) t.gameObject.layer = l;
        }

        void OnCollisionEnter(Collision c)
        {
            if (grab && grab.PendingLateRelease) grab.FinishLateRelease();
            Collided(c.collider, c.relativeVelocity, c.contactCount > 0 ? c.GetContact(0).point : transform.position, Time.time);
        }

        // A continuing contact can redirect it too. Don't carry the pre-solver direction past that contact.
        void OnCollisionStay(Collision _) => velocityBefore = Vector3.zero;

        /// <summary>Report a contact; true if the registered sink accepted it as the hit for this throw.</summary>
        public bool Collided(Collider other, Vector3 relativeVelocity, Vector3 point, float now)
        {
            var incoming = PropHit.Incoming(velocityBefore, relativeVelocity);
            velocityBefore = Vector3.zero;
            if (!inFlight || !other) return false;
            LaunchedPropContacted?.Invoke(this, other);
            var sink = HitSink;
            if (!inFlight || sink == null || (sink is Object owner && !owner)) return false;
            var target = sink.ResolveTarget(other);
            var speed = relativeVelocity.magnitude;
            if (!target || !float.IsFinite(speed) || !hits.Accept(speed, now)) return false;
            sink.OnHit(new PropHit(target, gameObject, speed, point, other, incoming));
            return true;
        }

        public uint ScriptedThrowSequence { get; private set; }

        /// <summary>Start a hit window for a launch performed by an external driver.</summary>
        public void Thrown(float now)
        {
            ScriptedThrowSequence++;
            BeginFlight(now);
        }

        void BeginFlight(float now)
        {
            inFlight = true;
            hits.Thrown(now);
        }

        void FixedUpdate()
        {
            velocityBefore = body && !body.isKinematic ? body.linearVelocity : Vector3.zero;
        }

        void Update() => Tick(Time.time, Time.deltaTime);

        /// <summary>Advance the respawn and collision policy with the supplied gameplay clock.</summary>
        public void Tick(float now, float dt)
        {
            SetLayer(layer.Layer(now));
            neighbours.Tick(layer.Active(now));
            pairs.Tick();
            if (Held || Stuck || (!body.IsSleeping() && body.linearVelocity.sqrMagnitude > RestSpeed * RestSpeed)) idle = 0f;
            else idle += dt;
            outOfArea = !Held && !Stuck && PropRespawnRules.OutOfArea(transform.position, RespawnSettings) ? outOfArea + dt : 0f;
            // Falling out of the world is a safety net even for owner-managed props (respawns=false).
            // Never fight an attachment: the late-release ride still belongs to XR after isSelected clears.
            if (Stuck || now < nextCheck || Held || grab.PendingLateRelease) return;
            nextCheck = now + CheckInterval;
            var reason = PropRespawnRules.Check(transform.position, homePosition, idle, InHomeArea(transform.position), outOfArea, respawns, RespawnSettings);
            if (reason == RespawnReason.None) return;
            var cam = Camera.main;
            var inView = cam && PropRespawnRules.InView(cam.transform.position, cam.transform.forward, transform.position, RespawnSettings);
            if (PropRespawnRules.PopNow(reason, inView))
            {
                if (reason == RespawnReason.Fell)
                {
                    if (RecoverFromFall != null)
                    {
                        ClearThrow();
                        RecoverFromFall(this);
                        return; // the owner may destroy us; never fall back to the captured home
                    }
                }
                Respawn();
            }
        }

        /// <summary>Seconds it has lain untouched (the idle respawn after <see cref="PropRespawnSettings.IdleSeconds"/>; tests).</summary>
        public float Idle => idle;

        /// <summary>Restart the idle clock after an owner lets go of the prop.</summary>
        public void ResetIdle() => idle = 0f;

        /// <summary>Nothing in flight any more (put back somewhere by its owner): no hit counts until the next throw.</summary>
        public void ClearThrow()
        {
            MotionRevision++;
            hits.Reset();
            inFlight = false;
            neighbours?.Clear();
            pairs?.Clear();
            idle = 0f;
        }

        /// <summary>Back to the home spot, at rest.</summary>
        public bool InHomeArea(Vector3 p) => homeArea.size != Vector3.zero && homeArea.Contains(p);

        public void Respawn()
        {
            if (Stuck) return; // it stays in whatever holds it until it falls or is pulled out
            if (ReturnHome != null)
            {
                ClearThrow();
                ReturnHome();
            }
            else PutHome();
        }

        /// <summary>Back to the home spot, at rest, with nothing in flight (what <see cref="Respawn"/> does without a <see cref="ReturnHome"/>).</summary>
        public void PutHome()
        {
            MotionRevision++;
            if (!body.isKinematic)
            {
                body.linearVelocity = Vector3.zero;
                body.angularVelocity = Vector3.zero;
            }
            body.position = homePosition;
            body.rotation = homeRotation;
            transform.SetPositionAndRotation(homePosition, homeRotation);
            // Its original stack may have been removed: let gravity find support again.
            if (!body.isKinematic && body.useGravity) body.WakeUp();
            else body.Sleep();
            hits.Reset();
            inFlight = false;
            neighbours?.Clear();
            pairs?.Clear();
            idle = outOfArea = 0f;
        }
    }
}
