using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.Controls;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Inputs.Readers;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning;
using YetiKit.Hands;

namespace Game.Starter
{
    // Poll tracking independently of the controller interactor's active state.
    [DefaultExecutionOrder(XRInteractionUpdateOrder.k_LocomotionProviders - 1)]
    public sealed class ControllerTracking : MonoBehaviour
    {
        [SerializeField] PlayerHand hand;
        [SerializeField] XRDirectInteractor direct;
        [SerializeField] XRRayInteractor teleport;
        [SerializeField] HandSnapTurn handTurn;
        [SerializeField] SnapTurnProvider turn;
        [SerializeField] InputAction tracked;
        const int FullPose = (int)(UnityEngine.XR.InputTrackingState.Position | UnityEngine.XR.InputTrackingState.Rotation);

        XRInputValueReader<Vector2> TurnInput => hand.RightHand ? turn.rightHandTurnInput : turn.leftHandTurnInput;

        public void Configure(PlayerHand playerHand, XRDirectInteractor grab, XRRayInteractor ray,
            HandSnapTurn trackedTurn, SnapTurnProvider snapTurn, string device)
        {
            hand = playerHand;
            direct = grab;
            teleport = ray;
            handTurn = trackedTurn;
            turn = snapTurn;
            tracked = new InputAction("Tracked", InputActionType.PassThrough, device + "/isTracked");
        }

        void OnEnable() => tracked.Enable();

        void OnDisable()
        {
            tracked.Disable();
            SetControllerActive(false);
        }

        void Update()
        {
            foreach (var control in tracked.controls)
            {
                // Some hand-interaction profiles are XRController layouts too. Require the
                // physical controller controls this rig uses, and read pose from that device only.
                if (control is not ButtonControl button || button.ReadValue() < 0.5f ||
                    control.device is not UnityEngine.InputSystem.XR.XRController device ||
                    (device.trackingState.ReadValue() & FullPose) != FullPose ||
                    InputControlPath.TryFindChild<ButtonControl>(device, "{GripButton}") == null ||
                    InputControlPath.TryFindChild<ButtonControl>(device, "{TriggerButton}") == null ||
                    InputControlPath.TryFindChild<Vector2Control>(device, "{Primary2DAxis}") is not { } stick)
                    continue;

                direct.transform.SetLocalPositionAndRotation(device.devicePosition.ReadValue(), device.deviceRotation.ReadValue());
                SetControllerActive(true);
                handTurn.Input.Pulse(0); // discard a hand pulse from before takeover
                var axis = stick.ReadValue();
                TurnInput.manualValue = Mathf.Abs(axis.x) >= 0.7f && Mathf.Abs(axis.x) > Mathf.Abs(axis.y)
                    ? new Vector2(Mathf.Sign(axis.x), 0f) : Vector2.zero;
                hand.Report(direct.selectInput.ReadValue(), teleport.selectInput.ReadValue());
                return;
            }
            SetControllerActive(false);
        }

        void SetControllerActive(bool active)
        {
            // Disabling the ray cancels selection, which must not confirm a teleport.
            teleport.gameObject.SetActive(active && !direct.hasSelection);
            if (direct.gameObject.activeSelf != active)
            {
                direct.gameObject.SetActive(active);
                if (active) hand.Sync(); // ends a prior hand grab before XRI processes this side
            }
            if (!active) TurnInput.manualValue = Vector2.zero;
        }
    }
}
