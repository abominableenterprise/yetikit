using System.Linq;
using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Interactables;
using YetiKit.Hands;
using YetiKit.Interaction;

namespace YetiKit.Lab
{
    [DisallowMultipleComponent]
    [RequireComponent(typeof(GrabbableProp))]
    public sealed class GripLabSlot : MonoBehaviour
    {
        bool atRestInSlot;
        readonly Collider[] contacts = new Collider[16];
        GrabbableProp prop;
        PropGrabInteractable grab;
        GripLabStation station;
        Pose home;
        float elapsed;

        public bool IsFixedInSlot => atRestInSlot;
        public string Id { get; private set; }
        internal Collider[] Solids { get; private set; }

        internal void Configure(GripLabStation owner, InteractableEntry entry)
        {
            station = owner;
            Id = entry.Id;
            Solids = GetComponentsInChildren<Collider>()
                .Where(c => !c.isTrigger && c.attachedRigidbody == prop.Body).ToArray();
            prop.respawns = false;
        }

        void Awake()
        {
            prop = GetComponent<GrabbableProp>();
            grab = GetComponent<PropGrabInteractable>();
        }

        void OnEnable()
        {
            grab.Grabbing += OnGrabbing;
            grab.selectEntered.AddListener(OnSelected);
            prop.RecoverFromFall += Recover;
        }

        void OnDisable()
        {
            grab.Grabbing -= OnGrabbing;
            grab.selectEntered.RemoveListener(OnSelected);
            prop.RecoverFromFall -= Recover;
        }

        internal void SetHome(Pose pose)
        {
            home = pose;
            ReturnHome();
        }

        internal void ReturnHome()
        {
            if (grab.isSelected && grab.interactionManager)
                grab.interactionManager.CancelInteractableSelection((IXRSelectInteractable)grab);
            prop.SetStuck(false);
            prop.ClearThrow();
            var body = prop.Body;
            if (!body.isKinematic) body.linearVelocity = body.angularVelocity = Vector3.zero;
            body.isKinematic = true;
            body.position = home.position;
            body.rotation = home.rotation;
            transform.SetPositionAndRotation(home.position, home.rotation);
            elapsed = 0;
            atRestInSlot = true;
        }

        void Recover(GrabbableProp _) { if (station) ReturnHome(); }

        internal void Tick(float dt)
        {
            if (atRestInSlot) return;
            elapsed = ReturnRules.Tick(elapsed, grab.isSelected || grab.PendingLateRelease, dt);
            if (ReturnRules.Due(elapsed)) ReturnHome();
        }

        void OnGrabbing(PropGrabInteractable _)
        {
            // XRI snapshots the body flags before its select events. Give it a dynamic body first.
            Release();
            elapsed = 0;
        }

        void OnSelected(SelectEnterEventArgs args)
        {
            if (!station || !station.Head) return;
            var hand = PlayerHand.Of(args.interactorObject.transform) ?? ControllerMotion.Of(args.interactorObject.transform)?.hand;
            var attach = args.interactorObject.GetAttachTransform(grab);
            if (!hand || !hand.Present || !attach) return;
            var wrist = hand.HandTracked ? hand.WristPose : hand.PalmPose;
            var head = station.Head;
            station.FlightEvents.Record(Id, hand.RightHand, grab.GripMode, prop.GripIdFor(grab.GripMode),
                new Pose(attach.position, attach.rotation), wrist, new Pose(head.position, head.rotation));
        }

        void Release()
        {
            if (!atRestInSlot) return;
            atRestInSlot = false;
            prop.Body.isKinematic = false;
            prop.Body.WakeUp();
        }

        void FixedUpdate()
        {
            // Two kinematic bodies may not receive a collision callback. Broad-phase candidates must
            // be physical hand colliders and actually penetrate the display collider.
            if (!atRestInSlot) return;
            foreach (var own in Solids)
            {
                if (!own || !own.enabled || !own.gameObject.activeInHierarchy) continue;
                var bounds = own.bounds;
                var hits = contacts;
                var count = Physics.OverlapBoxNonAlloc(bounds.center, bounds.extents, hits,
                    Quaternion.identity, Physics.AllLayers, QueryTriggerInteraction.Ignore);
                if (count == hits.Length)
                {
                    hits = Physics.OverlapBox(bounds.center, bounds.extents, Quaternion.identity,
                        Physics.AllLayers, QueryTriggerInteraction.Ignore);
                    count = hits.Length;
                }
                for (var i = 0; i < count; i++)
                {
                    var other = hits[i];
                    if (other.attachedRigidbody == prop.Body || !PlayerHand.Of(other.transform) ||
                        Physics.GetIgnoreLayerCollision(own.gameObject.layer, other.gameObject.layer) ||
                        Physics.GetIgnoreCollision(own, other)) continue;
                    if (!Physics.ComputePenetration(own, own.transform.position, own.transform.rotation,
                            other, other.transform.position, other.transform.rotation, out _, out _)) continue;
                    Release();
                    return;
                }
            }
        }
    }
}
