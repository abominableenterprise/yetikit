namespace YetiKit.Hands
{
    /// <summary>Optional opacity hook. Implementations own their avatar's material and blend settings.</summary>
    public interface IHandVisualAlpha : IHandVisual
    {
        /// <summary>Visual opacity in [0, 1], where 1 is fully opaque.</summary>
        float Alpha { get; set; }
    }
}
