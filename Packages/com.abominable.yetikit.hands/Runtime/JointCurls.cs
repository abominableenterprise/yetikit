namespace YetiKit.Hands
{
    /// <summary>
    /// Every finger joint's curl on its own (0 straight, 1 the fist's angle for that joint), for poses one curl per
    /// finger cannot express: each joint can bend by a different amount when conforming to a surface.
    /// </summary>
    public sealed class JointCurls
    {
        public const int Joints = 3;
        readonly float[] values = new float[FingerCurls.Fingers * Joints];

        public float this[int finger, int joint]
        {
            get => values[finger * Joints + joint];
            set => values[finger * Joints + joint] = value;
        }

        /// <summary>The same curl on every joint of each finger (how <see cref="FingerCurls"/> curls).</summary>
        public static JointCurls From(FingerCurls pose)
        {
            var c = new JointCurls();
            for (var f = 0; f < FingerCurls.Fingers; f++)
                for (var j = 0; j < Joints; j++) c[f, j] = pose[f];
            return c;
        }
    }
}
