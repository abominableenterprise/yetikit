using System;
using System.Linq;
using Game.Starter;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning;
using YetiKit.Lab;

namespace Game.Dev
{
    // The sandbox scene has no serialized dependency on the dev assembly.
    public sealed class StarterLab : MonoBehaviour
    {
        public const string ScenePath = "Assets/Starter/Sandbox/Sandbox.unity";
        public const string Compact = "snap-30", Wide = "snap-45";
        const string LaunchFlag = "--starter-experiment";
        const string Scope = "starter-sandbox";

        SnapTurnProvider turn;
        Camera photoCamera;
        float roomDefault, experimentDefault;
        Tuning tuning;

        public string CurrentId { get; private set; }
        public string SuggestedId { get; private set; }
        public ITuningBinding Angle { get; private set; }
        public bool HasOverride => Angle != null && Angle.Get() != Angle.Default;
        internal float SnapAngle => turn.turnAmount;
        internal string PhotoStatus { get; private set; }
        internal string PhotoDirectory { get; set; }

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.SubsystemRegistration)]
        static void ResetHooks() => SceneManager.sceneLoaded -= OnSceneLoaded;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        static void Boot()
        {
            SceneManager.sceneLoaded += OnSceneLoaded;
            var scene = SceneManager.GetActiveScene();
            var sandbox = FindSandbox(scene);
            if (sandbox)
            {
                // The requested target is already loaded; hand the selection to this scene without reloading it.
                TryDirectBoot(Environment.GetCommandLineArgs(), scene.path, _ => { });
                Install(sandbox, scene);
            }
            else if (Application.CanStreamedLevelBeLoaded(ScenePath))
                TryDirectBoot(Environment.GetCommandLineArgs(), ScenePath);
        }

        public static bool TryDirectBoot(string[] args, string targetScene, Action<string> load = null)
        {
            var index = Array.IndexOf(args, LaunchFlag);
            return index >= 0 && index + 1 < args.Length && Known(args[index + 1]) &&
                DevBoot.Launch(() => (targetScene, args[index + 1]), load);
        }

        static bool Known(string id) => id == Compact || id == Wide;

        static SandboxBindings FindSandbox(Scene scene) => scene.GetRootGameObjects()
            .Select(root => root.GetComponent<SandboxBindings>()).FirstOrDefault(bindings => bindings);

        static void OnSceneLoaded(Scene scene, LoadSceneMode mode)
        {
            var sandbox = FindSandbox(scene);
            if (sandbox) Install(sandbox, scene);
        }

        static void Install(SandboxBindings sandbox, Scene scene)
        {
            if (sandbox.TryGetComponent<StarterLab>(out _)) return;
            var turn = scene.GetRootGameObjects().Select(root => root.GetComponent<SnapTurnProvider>())
                .FirstOrDefault(provider => provider);
            if (!turn) return;
            var lab = sandbox.gameObject.AddComponent<StarterLab>();
            lab.turn = turn;
            lab.roomDefault = turn.turnAmount;
            lab.photoCamera = turn.GetComponentInChildren<Camera>();
            lab.PhotoDirectory = Application.persistentDataPath;
            // A direct launch does not change the last explicit choice.
            lab.SuggestedId = new PlayerPrefsExperimentSelectionStore().Load(Scope);
            var direct = DevBoot.Consume(scene.path);
            if (Known(direct)) lab.Bind(direct);
            StarterLabPanel.Build(lab);
            StarterWristPanel.Build(lab, turn.transform);
        }

        public bool Select(string id)
        {
            if (!Known(id)) return false;
            if (id != CurrentId) Bind(id);
            new PlayerPrefsExperimentSelectionStore().Save(Scope, id);
            SuggestedId = id;
            return true;
        }

        void Bind(string id)
        {
            tuning?.Flush();
            experimentDefault = id == Compact ? 30f : 45f;
            PhotoStatus = null;
            // Lab bindings apply saved overrides on registration, but callers supply the live default first.
            turn.turnAmount = experimentDefault;
            var experimentId = Scope + "." + id;
            tuning = StarterTuningDocument.CanPersist(experimentId) ? new Tuning(experimentId) : null;
            Angle = tuning?.Float("Snap turn", () => turn.turnAmount, value => turn.turnAmount = value,
                experimentDefault, min: 15f, max: 90f, step: 5f);
            CurrentId = id;
        }

        internal void SnapPhoto()
        {
            if (CurrentId == null) return;
            PhotoStatus = StarterPhoto.Save(PhotoDirectory, photoCamera, new StarterPhoto.Context
            {
                experiment = CurrentId,
                snapTurnDegrees = SnapAngle,
                defaultSnapTurnDegrees = experimentDefault,
                hasOverride = HasOverride,
                tuningPersistenceAvailable = Angle != null
            });
        }

        internal void ResetAngle()
        {
            tuning?.ResetAll();
            tuning?.Flush();
        }

        void Update() => tuning?.Tick(Time.unscaledTimeAsDouble);
        void OnApplicationPause(bool paused) { if (paused) tuning?.Flush(); }
        void OnDisable() => tuning?.Flush();
        void OnDestroy()
        {
            tuning?.Flush();
            if (turn) turn.turnAmount = roomDefault;
        }
    }
}
