namespace YetiKit.Hands
{
    public enum HandShape { Relaxed, Open, Fist, Point, Bird }

    /// <summary>
    /// A tracked hand's shape from its finger curls (pure; <see cref="HandCurls.PerFinger"/>, 0 straight, 1 a fist),
    /// with hysteresis: a shape is entered with the strict thresholds and kept with the loose ones, so a finger hovering
    /// at a threshold does not flicker the bird or a fist on and off. The thumb is ignored (free in every shape).
    /// Fist: index, middle, ring, little curled. Open: all four straight. Point: index straight, the rest curled.
    /// Bird: middle straight, index, ring, little curled. Anything else is Relaxed.
    /// </summary>
    public sealed class HandShapeClassifier
    {
        public const float CurledEnter = 0.6f, CurledStay = 0.45f;   // a curled finger: enter at or above, stay at or above
        public const float StraightEnter = 0.3f, StraightStay = 0.42f; // a straight finger: enter at or below, stay at or below

        public HandShape Shape { get; private set; } = HandShape.Relaxed;

        public void Reset() => Shape = HandShape.Relaxed;

        /// <summary>Classify this frame's curls (the current shape keeps the loose thresholds).</summary>
        public HandShape Tick(FingerCurls c)
        {
            // Keep the current shape while it still holds loosely; otherwise the first shape that holds strictly.
            if (Shape != HandShape.Relaxed && Holds(Shape, c, true)) return Shape;
            foreach (var s in Order)
                if (Holds(s, c, false)) return Shape = s;
            return Shape = HandShape.Relaxed;
        }

        /// <summary>The point/pinch-ready family: thumb free, index may bend for a pinch,
        /// but all three other fingers must curl.</summary>
        public static bool MenuPoint(FingerCurls c, bool loose)
        {
            var curled = loose ? CurledStay : CurledEnter;
            return c.index < CurledEnter && c.middle >= curled && c.ring >= curled && c.pinky >= curled;
        }

        static readonly HandShape[] Order = { HandShape.Bird, HandShape.Point, HandShape.Fist, HandShape.Open };

        /// <summary>Does <paramref name="c"/> make <paramref name="shape"/> (with the stay thresholds when <paramref name="loose"/>)?</summary>
        public static bool Holds(HandShape shape, FingerCurls c, bool loose)
        {
            var curled = loose ? CurledStay : CurledEnter;
            var straight = loose ? StraightStay : StraightEnter;
            bool Curled(float v) => v >= curled;
            bool Straight(float v) => v <= straight;
            return shape switch
            {
                HandShape.Fist => Curled(c.index) && Curled(c.middle) && Curled(c.ring) && Curled(c.pinky),
                HandShape.Open => Straight(c.index) && Straight(c.middle) && Straight(c.ring) && Straight(c.pinky),
                HandShape.Point => Straight(c.index) && Curled(c.middle) && Curled(c.ring) && Curled(c.pinky),
                HandShape.Bird => Straight(c.middle) && Curled(c.index) && Curled(c.ring) && Curled(c.pinky),
                _ => false,
            };
        }
    }
}
