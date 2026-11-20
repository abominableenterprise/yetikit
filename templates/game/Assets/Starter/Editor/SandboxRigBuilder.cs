using Unity.XR.CoreUtils;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.XR;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Inputs.Readers;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Interactors.Visuals;
using UnityEngine.XR.Interaction.Toolkit.Locomotion;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Teleportation;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning;
using YetiKit.Hands;
using YetiKit.Interaction;

namespace Game.Starter.Editor
{
    static class SandboxRigBuilder
    {
        // Default is sufficient for TeleportAim, which also requires a TeleportationArea.
        // Use a separate scene-local mask for the props, without modifying project settings.
        internal const int PropsMask = 1 << 1;
        const int PadsMask = 1;
        const float PadSize = 0.95f, PadHeight = 0.02f;
        const float SnapDegrees = 30f;

        public static void Build(XRInteractionManager manager, Material pads, Material lineMaterial, SandboxRigVisuals visuals)
        {
            var root = new GameObject("XR Origin");
            root.SetActive(false);
            root.transform.position = new Vector3(0, 0, -0.55f);
            var space = Child(root.transform, "Tracking Space");
            var head = Child(space.transform, "Camera");
            head.tag = "MainCamera";
            head.transform.SetLocalPositionAndRotation(new Vector3(0, 1.6f, 0), Quaternion.Euler(12, 0, 0));
            head.AddComponent<AudioListener>();
            BindPose(head, "<XRHMD>");
            var origin = root.AddComponent<XROrigin>();
            origin.Origin = root;
            origin.CameraFloorOffsetObject = space;
            origin.Camera = head.AddComponent<Camera>();

            root.AddComponent<XRBodyTransformer>().xrOrigin = origin;
            var mediator = root.AddComponent<LocomotionMediator>();
            var teleport = root.AddComponent<TeleportationProvider>();
            teleport.mediator = mediator;
            var turn = root.AddComponent<SnapTurnProvider>();
            turn.mediator = mediator;
            turn.turnAmount = SnapDegrees;
            turn.enableTurnAround = false;
            turn.leftHandTurnInput.inputSourceMode = XRInputValueReader.InputSourceMode.ManualValue;
            turn.rightHandTurnInput.inputSourceMode = XRInputValueReader.InputSourceMode.ManualValue;

            BuildSide(space.transform, head.transform, manager, teleport, turn, lineMaterial, visuals, false);
            BuildSide(space.transform, head.transform, manager, teleport, turn, lineMaterial, visuals, true);
            Pad("Left Teleport Pad", new Vector3(-1.8f, 0f, 1.45f), manager, teleport, pads);
            Pad("Right Teleport Pad", new Vector3(1.8f, 0f, 1.45f), manager, teleport, pads);
            root.SetActive(true);
        }

        static void BuildSide(Transform space, Transform head, XRInteractionManager manager,
            TeleportationProvider teleport, SnapTurnProvider turn, Material lineMaterial, SandboxRigVisuals visuals, bool right)
        {
            var side = right ? "RightHand" : "LeftHand";
            var device = "<XRController>{" + side + "}";
            // The controller and hand must be siblings in the same tracking space.
            var controller = Child(space, side + " Controller");
            controller.SetActive(false);
            var direct = Direct<XRDirectInteractor>(controller, manager);
            direct.selectInput = Button(device, "{GripButton}", "{Grip}");
            var rayRoot = Child(controller.transform, "Teleport Ray");
            var ray = rayRoot.AddComponent<XRRayInteractor>();
            ray.interactionManager = manager;
            ray.interactionLayers = PadsMask;
            ray.enableUIInteraction = false;
            ray.useForceGrab = false;
            ray.hitClosestOnly = true;
            ray.raycastTriggerInteraction = QueryTriggerInteraction.Ignore;
            ray.lineType = XRRayInteractor.LineType.ProjectileCurve;
            ray.referenceFrame = space;
            ray.velocity = 5f;
            ray.acceleration = 9.8f;
            ray.selectInput = Button(device, "{TriggerButton}", "{Trigger}");
            Line(rayRoot, lineMaterial);
            var visual = rayRoot.AddComponent<XRInteractorLineVisual>();
            visual.lineWidth = 0.012f;
            visual.validColorGradient = ColorRamp(Color.cyan);
            visual.invalidColorGradient = ColorRamp(new Color(1f, 0.3f, 0.15f));

            var handRoot = Child(space, side + " Hand");
            var hand = handRoot.AddComponent<PlayerHand>();
            hand.rightHand = right;
            hand.controller = controller.transform;
            hand.grabber = Direct<HandGrabInteractor>(Child(handRoot.transform, "Palm Grab"), manager);
            hand.grabber.hand = hand;
            hand.grabber.enabled = false;
            var motion = handRoot.AddComponent<ControllerMotion>();
            motion.hand = hand;
            motion.rightHand = right;
            var aim = handRoot.AddComponent<HandTeleport>();
            aim.hand = hand;
            aim.head = head;
            aim.provider = teleport;
            aim.controllerRay = ray;
            aim.TeleportLayerName = "Default";
            aim.line = Line(handRoot, lineMaterial);
            aim.validColor = visual.validColorGradient;
            aim.invalidColor = visual.invalidColorGradient;
            var handTurn = handRoot.AddComponent<HandSnapTurn>();
            handTurn.hand = hand;
            handTurn.head = head;
            handTurn.teleport = aim;
            handTurn.provider = turn;

            handRoot.AddComponent<ControllerTracking>().Configure(hand, direct, ray, handTurn, turn, device);
            visuals.Build(hand);
        }

        static T Direct<T>(GameObject root, XRInteractionManager manager) where T : XRDirectInteractor
        {
            var sphere = root.AddComponent<SphereCollider>();
            sphere.isTrigger = true;
            sphere.radius = HandGrabInteractor.Radius;
            var direct = root.AddComponent<T>();
            direct.interactionManager = manager;
            direct.interactionLayers = PropsMask;
            direct.improveAccuracyWithSphereCollider = true;
            direct.physicsTriggerInteraction = QueryTriggerInteraction.Ignore;
            return direct;
        }

        static XRInputButtonReader Button(string device, string press, string value) =>
            new(inputSourceMode: XRInputButtonReader.InputSourceMode.InputAction)
            {
                inputActionPerformed = new InputAction("Press", InputActionType.Button, device + "/" + press),
                inputActionValue = new InputAction("Value", InputActionType.Value, device + "/" + value),
            };

        static void BindPose(GameObject root, string device)
        {
            var pose = root.AddComponent<TrackedPoseDriver>();
            pose.positionInput = PoseInput("Position", "devicePosition");
            pose.rotationInput = PoseInput("Rotation", "deviceRotation");
            pose.trackingStateInput = PoseInput("Tracking State", "trackingState");
            InputActionProperty PoseInput(string name, string control) =>
                new(new InputAction(name, InputActionType.PassThrough, device + "/" + control));
        }

        static void Pad(string name, Vector3 center, XRInteractionManager manager, TeleportationProvider provider, Material material)
        {
            var pad = GameObject.CreatePrimitive(PrimitiveType.Cube);
            pad.name = name;
            pad.transform.position = center + Vector3.up * (PadHeight / 2);
            pad.transform.localScale = new Vector3(PadSize, PadHeight, PadSize);
            pad.GetComponent<Renderer>().sharedMaterial = material;
            var area = pad.AddComponent<TeleportationArea>();
            area.interactionManager = manager;
            area.interactionLayers = PadsMask;
            area.teleportationProvider = provider;
            area.matchOrientation = MatchOrientation.WorldSpaceUp;
            area.teleportTrigger = BaseTeleportationInteractable.TeleportTrigger.OnSelectExited;
            area.filterSelectionByHitNormal = true;
            area.upNormalToleranceDegrees = 30;
        }

        static GameObject Child(Transform parent, string name)
        {
            var child = new GameObject(name);
            child.transform.SetParent(parent, false);
            return child;
        }

        static LineRenderer Line(GameObject root, Material material)
        {
            var line = root.AddComponent<LineRenderer>();
            line.enabled = false;
            line.sharedMaterial = material;
            line.widthMultiplier = 0.012f;
            return line;
        }

        static Gradient ColorRamp(Color color)
        {
            var gradient = new Gradient();
            gradient.SetKeys(new[] { new GradientColorKey(color, 0f), new GradientColorKey(color, 1f) },
                new[] { new GradientAlphaKey(1f, 0f), new GradientAlphaKey(1f, 1f) });
            return gradient;
        }
    }
}
