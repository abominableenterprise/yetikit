using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.XR.Interaction.Toolkit;
using UnityEngine.XR.Interaction.Toolkit.Inputs.Readers;
using UnityEngine.XR.Interaction.Toolkit.Interactors;
using UnityEngine.XR.Interaction.Toolkit.Locomotion.Turning;
using YetiKit.Hands;

namespace Game.Starter
{
    // Keep the pose driver independent of the controller interactor's active state, so it can
    // receive the first tracked pose before PlayerHand sees an active controller.
    [DefaultExecutionOrder(XRInteractionUpdateOrder.k_LocomotionProviders - 1)]
    public sealed class ControllerTracking : MonoBehaviour
    {
        [SerializeField] PlayerHand hand;
        [SerializeField] XRDirectInteractor direct;
        [SerializeField] XRRayInteractor teleport;
        [SerializeField] HandSnapTurn handTurn;
        [SerializeField] SnapTurnProvider turn;
        [SerializeField] InputAction tracked, stick;

        XRInputValueReader<Vector2> TurnInput => hand.RightHand ? turn.rightHandTurnInput : turn.leftHandTurnInput;

        public void Configure(PlayerHand playerHand, XRDirectInteractor grab, XRRayInteractor ray,
            HandSnapTurn trackedTurn, SnapTurnProvider snapTurn, string device)
        {
            hand = playerHand;
            direct = grab;
            teleport = ray;
            handTurn = trackedTurn;
            turn = snapTurn;
            tracked = new InputAction("Tracked", InputActionType.Button, device + "/isTracked");
            stick = new InputAction("Turn", InputActionType.Value, device + "/{Primary2DAxis}");
        }

        void OnEnable()
        {
            tracked.Enable();
            stick.Enable();
        }

        void OnDisable()
        {
            tracked.Disable();
            stick.Disable();
            SetControllerActive(false);
        }

        void Update()
        {
            var active = tracked.IsPressed();
            if (active) direct.transform.SetLocalPositionAndRotation(transform.localPosition, transform.localRotation);
            SetControllerActive(active);
            if (!active) return;
            // Discard a hand pulse left over from the previous frame at controller takeover.
            handTurn.Input.Pulse(0);
            var axis = stick.ReadValue<Vector2>();
            TurnInput.manualValue = Mathf.Abs(axis.x) >= 0.7f && Mathf.Abs(axis.x) > Mathf.Abs(axis.y)
                ? new Vector2(Mathf.Sign(axis.x), 0f) : Vector2.zero;
            hand.Report(direct.selectInput.ReadValue(), teleport.selectInput.ReadValue());
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
