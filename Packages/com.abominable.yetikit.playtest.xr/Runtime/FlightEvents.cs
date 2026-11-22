using System;
using System.Text;
using UnityEngine;
using YetiKit.Interaction;

namespace YetiKit.Playtest.XR
{
    /// <summary>Records one prop's selection and committed throws under a caller-provided, nonpersonal ID.</summary>
    public sealed class FlightEvents : IFlightEventSource
    {
        readonly PropGrabInteractable prop;
        readonly string payload;
        Action<string, string> listeners;
        Vector3? pendingThrow;

        public FlightEvents(PropGrabInteractable prop, string id)
        {
            if (!prop) throw new ArgumentNullException(nameof(prop));
            if (string.IsNullOrWhiteSpace(id)) throw new ArgumentException("A prop ID is required.", nameof(id));
            this.prop = prop;
            payload = JsonLine.Str(new StringBuilder("{\"id\":"), id).Append('}').ToString();
        }

        /// <summary>
        /// Subscribes to the prop only while at least one listener is registered. Use on the main thread.
        /// Every settled selection emits a release; a committed launch emits a throw immediately after it.
        /// </summary>
        public event Action<string, string> Event
        {
            add
            {
                if (value == null) return;
                var attach = listeners == null;
                listeners += value;
                if (!attach) return;
                prop.Grabbing += OnGrab;
                prop.LaunchedFromHand += OnLaunch;
                prop.Released += OnRelease;
            }
            remove
            {
                if (listeners == null || value == null) return;
                listeners -= value;
                if (listeners != null) return;
                prop.Grabbing -= OnGrab;
                prop.LaunchedFromHand -= OnLaunch;
                prop.Released -= OnRelease;
                pendingThrow = null;
            }
        }

        void OnGrab(PropGrabInteractable sender)
        {
            pendingThrow = null;
            listeners?.Invoke("grab", payload);
        }

        void OnLaunch()
        {
            // The committed-release callback also fires for drops, but never for forced releases or passes.
            pendingThrow = prop.Launched ? prop.ReleaseVelocity : (Vector3?)null;
        }

        void OnRelease(PropGrabInteractable sender, Transform interactor)
        {
            var velocity = pendingThrow;
            pendingThrow = null;
            listeners?.Invoke("release", payload);
            if (!velocity.HasValue || listeners == null) return;

            var json = new StringBuilder(payload, 0, payload.Length - 1, payload.Length + 40);
            JsonLine.Vec3(JsonLine.Key(json, "v"), velocity.Value, JsonLine.SpeedDecimals);
            listeners?.Invoke("throw", json.Append('}').ToString());
        }
    }
}
