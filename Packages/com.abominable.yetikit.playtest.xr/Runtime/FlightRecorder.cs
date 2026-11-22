using System;
using System.IO;
using UnityEngine;
using UnityEngine.XR;

namespace YetiKit.Playtest.XR
{
    /// <summary>Explicit opt-in to a local XR recording, for the lifetime of the app.</summary>
    public static class PlaytestXR
    {
        static FlightRecorder active;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        static void Reset() => active = null;

        /// <summary>Call on the main thread in Play Mode. Repeated calls return the same recorder.
        /// Returns null in batch mode or outside Editor/development play.</summary>
        public static FlightRecorder Attach(IPlayerIdentity player = null, IBuildIdentity build = null,
            params IFlightEventSource[] sources)
        {
            if (Application.isBatchMode || !Application.isPlaying || !(Application.isEditor || Debug.isDebugBuild))
                return null;
            if (active) return active;

            var root = Path.Combine(Application.persistentDataPath, FileChunkStore.Folder);
            RecorderSession recording;
            try
            {
                recording = new RecorderSession(new FileChunkStore(root), () => Time.realtimeSinceStartupAsDouble,
                    () => DateTime.UtcNow, new HandSampler().Sample, player, build, sources);
            }
            catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
            {
                Debug.LogWarning("[Playtest XR] Could not recover local recordings; recording not started.");
                return null;
            }
            var host = new GameObject("Playtest XR Recorder");
            UnityEngine.Object.DontDestroyOnLoad(host);
            active = host.AddComponent<FlightRecorder>();
            active.Recording = recording;
            return active;
        }
    }

    /// <summary>Bridges Unity frame time and headset/application suspension into the recorder lifecycle.</summary>
    public sealed class FlightRecorder : MonoBehaviour
    {
        internal RecorderSession Recording { private get; set; }
        bool appPaused;

        void LateUpdate()
        {
            var headset = InputDevices.GetDeviceAtXRNode(XRNode.Head);
            var away = headset.TryGetFeatureValue(CommonUsages.userPresence, out var present) && !present;
            Recording?.Tick(Time.frameCount, Time.unscaledDeltaTime, appPaused || away);
        }

        void OnApplicationPause(bool paused)
        {
            appPaused = paused;
            // Flush even if Unity suspends before another LateUpdate.
            if (paused) Pause();
        }

        // Keep the coordinator alive so LateUpdate can resume it on re-enable.
        void OnDisable() => Pause();
        void Pause() => Recording?.Tick(Time.frameCount, 0, true);

        void OnApplicationQuit() => Stop();
        void OnDestroy() => Stop();

        void Stop()
        {
            var recording = Recording;
            Recording = null;
            recording?.Dispose();
        }
    }
}
