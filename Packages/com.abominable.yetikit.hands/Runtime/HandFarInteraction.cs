using System.Collections.Generic;

namespace YetiKit.Hands
{
    /// <summary>UI hover suppresses new near grabs. Each UI adapter clears only its own hover.</summary>
    public sealed class HandFarInteraction
    {
        readonly HashSet<object> uiOwners = new HashSet<object>();
        public bool UiHover => uiOwners.Count != 0;

        public void Hover(object owner, bool hovering)
        {
            if (hovering) uiOwners.Add(owner);
            else uiOwners.Remove(owner);
        }
    }
}
