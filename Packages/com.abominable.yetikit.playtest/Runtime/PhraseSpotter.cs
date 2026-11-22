using System;
using System.Threading;

namespace YetiKit.Playtest
{
    /// <summary>Consumes 16 kHz mono PCM16. Emit callbacks synchronously inside Accept;
    /// every endpoint emits a final, including when the text is empty.</summary>
    public interface IPhraseSpotter : IDisposable
    {
        event Action<string, bool> Phrase;
        void Accept(short[] pcm, int count);
    }

    /// <summary>Bind a key press in the host input system. The next Accept emits its final.</summary>
    public sealed class KeyboardPhraseSpotter : IPhraseSpotter
    {
        string pending;
        public event Action<string, bool> Phrase;

        // One pending input; false means the input is invalid or the slot is occupied.
        public bool TryFire(string phrase = "start") =>
            !string.IsNullOrWhiteSpace(phrase) && Interlocked.CompareExchange(ref pending, phrase, null) == null;

        public void Accept(short[] pcm, int count)
        {
            var text = Interlocked.Exchange(ref pending, null);
            if (text != null) Phrase?.Invoke(text, true);
        }

        public void Dispose() => Interlocked.Exchange(ref pending, null);
    }
}
