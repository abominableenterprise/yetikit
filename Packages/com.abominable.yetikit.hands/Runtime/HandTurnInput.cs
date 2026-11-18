using UnityEngine;
using UnityEngine.XR.Interaction.Toolkit.Inputs.Readers;

namespace YetiKit.Hands
{
    /// <summary>
    /// A bypass for one side's <see cref="UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning.SnapTurnProvider"/> turn
    /// input: a <see cref="Pulse"/> is read once as a full stick left or right; otherwise it returns the controller
    /// stick's own value (read through the bypass scope), so controller snap turning is unchanged.
    /// </summary>
    public sealed class HandTurnInput : IXRInputValueReader<Vector2>
    {
        XRInputValueReader<Vector2> raw;
        int pending;

        public bool Attached => raw != null && raw.bypass == this;
        public int Pending => pending;

        public void Attach(XRInputValueReader<Vector2> reader)
        {
            Detach();
            if (reader == null) return;
            raw = reader;
            raw.bypass = this;
        }

        public void Detach()
        {
            if (raw != null && raw.bypass == this) raw.bypass = null;
            raw = null;
            pending = 0;
        }

        /// <summary>Turn once: -1 left, +1 right (read on the provider's next update).</summary>
        public void Pulse(int direction) => pending = direction > 0 ? 1 : direction < 0 ? -1 : 0;

        public Vector2 ReadValue()
        {
            if (pending != 0)
            {
                var v = new Vector2(pending, 0f);
                pending = 0;
                return v;
            }
            return raw != null ? raw.ReadValue() : Vector2.zero;
        }

        public bool TryReadValue(out Vector2 value)
        {
            if (pending != 0)
            {
                value = ReadValue();
                return true;
            }
            if (raw != null) return raw.TryReadValue(out value);
            value = Vector2.zero;
            return false;
        }
    }
}
