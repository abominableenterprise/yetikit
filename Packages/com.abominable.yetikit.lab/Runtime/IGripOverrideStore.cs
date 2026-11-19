using YetiKit.Hands;

namespace YetiKit.Lab
{
    /// <summary>Stores one versioned JSON document per catalog ID and input mode.</summary>
    public interface IGripOverrideStore
    {
        /// <summary>Returns null if no override is stored for this key.</summary>
        string Load(string propId, HandMode mode);
        /// <summary>Replaces the document for this key, or removes it if body is null.</summary>
        void Save(string propId, HandMode mode, string body);
    }
}
