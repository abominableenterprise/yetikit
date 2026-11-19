using UnityEngine;

namespace YetiKit.Interaction
{
    /// <summary>The first eligible impact after a prop is thrown.</summary>
    public readonly struct PropHit
    {
        public readonly Component Target;
        public readonly GameObject Prop;
        public readonly float Speed;
        public readonly Vector3 Point;
        public readonly Collider Collider;
        /// <summary>Incoming velocity before any bounce, used for its direction.</summary>
        public readonly Vector3 Direction;

        public const float MinDirectionSqr = 0.01f;

        public PropHit(Component target, GameObject prop, float speed, Vector3 point, Collider collider,
            Vector3 direction)
        {
            Target = target;
            Prop = prop;
            Speed = speed;
            Point = point;
            Collider = collider;
            Direction = direction;
        }

        /// <summary>The incoming motion from before the contact, or the reverse of relative velocity.</summary>
        public static Vector3 Incoming(Vector3 velocityBefore, Vector3 relativeVelocity) =>
            velocityBefore.sqrMagnitude > MinDirectionSqr ? velocityBefore : -relativeVelocity;
    }

    /// <summary>Optional consumer registered on a prop to resolve and receive thrown impacts.</summary>
    public interface IThrownHitSink
    {
        /// <summary>Return the target (which may be the collider), or null for an ineligible contact.</summary>
        Component ResolveTarget(Collider collider);
        void OnHit(in PropHit hit);
    }
}
