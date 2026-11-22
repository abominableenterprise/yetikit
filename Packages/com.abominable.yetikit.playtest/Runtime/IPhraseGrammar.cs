using System.Collections.Generic;

namespace YetiKit.Playtest
{
    public interface IPhraseGrammar
    {
        IReadOnlyList<string> StartPhrases { get; }
        IReadOnlyList<string> SendPhrases { get; }
    }

    public sealed class DefaultPhraseGrammar : IPhraseGrammar
    {
        public IReadOnlyList<string> StartPhrases { get; } = System.Array.AsReadOnly(new[] { "start" });
        public IReadOnlyList<string> SendPhrases { get; } = System.Array.AsReadOnly(new[] { "send it" });
    }
}
