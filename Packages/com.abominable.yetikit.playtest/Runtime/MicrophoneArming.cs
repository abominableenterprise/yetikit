using System;

namespace YetiKit.Playtest
{
    public interface IMicrophonePermission
    {
        bool IsGranted { get; }
        void Request();
    }

    public interface IMicrophoneCapture
    {
        /// <summary>Returns false if no capture was started.</summary>
        bool TryStart();
        void Stop();
    }

    /// <summary>Host-driven on the main thread. Arm only on explicit opt-in; poll while armed and stop on teardown.</summary>
    public sealed class MicrophoneArming
    {
        readonly IMicrophonePermission permission;
        readonly IMicrophoneCapture capture;
        bool armed, requested;
        public bool IsCapturing { get; private set; }

        public MicrophoneArming(IMicrophonePermission permission, IMicrophoneCapture capture)
        {
            this.permission = permission ?? throw new ArgumentNullException(nameof(permission));
            this.capture = capture ?? throw new ArgumentNullException(nameof(capture));
        }

        /// <summary>Wait for permission, prompting at most once per instance. Does not start capture.</summary>
        public void Arm()
        {
            if (armed) return;
            armed = true;
            if (requested || permission.IsGranted) return;
            requested = true;
            permission.Request();
        }

        /// <summary>Starts capture on grant; revocation or a failed start requires a fresh Arm call.</summary>
        public void Poll()
        {
            if (!armed) return;
            if (!permission.IsGranted) { if (IsCapturing) Stop(); return; }
            if (!IsCapturing) armed = IsCapturing = capture.TryStart();
        }

        public void Stop()
        {
            var wasCapturing = IsCapturing;
            armed = IsCapturing = false;
            if (wasCapturing) capture.Stop();
        }
    }
}
