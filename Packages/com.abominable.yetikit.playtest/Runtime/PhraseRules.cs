using System;
using System.Collections.Generic;

namespace YetiKit.Playtest
{
    public enum PhraseTrigger { None, Start, SendIt }

    /// <summary>Exact words, ignoring case and whitespace. Use one matcher per recognition stream.</summary>
    public sealed class PhraseRules
    {
        readonly Dictionary<string, PhraseTrigger> commands = new Dictionary<string, PhraseTrigger>();
        readonly double debounce;
        readonly double[] last = { double.NegativeInfinity, double.NegativeInfinity };
        internal IEnumerable<string> Commands => commands.Keys;
        long latest = -1;
        bool closed;

        public PhraseRules(IPhraseGrammar grammar = null, double debounceSeconds = 3)
        {
            if (!(debounceSeconds >= 0 && debounceSeconds < double.PositiveInfinity)) throw new ArgumentOutOfRangeException(nameof(debounceSeconds));
            debounce = debounceSeconds;
            grammar = grammar ?? new DefaultPhraseGrammar();
            Add(grammar.StartPhrases, PhraseTrigger.Start);
            Add(grammar.SendPhrases, PhraseTrigger.SendIt);
        }

        void Add(IEnumerable<string> phrases, PhraseTrigger trigger)
        {
            foreach (var phrase in phrases)
            {
                var normalized = Normalize(phrase);
                if (normalized.Length == 0 || normalized.Contains("[unk]")) throw new ArgumentException("Invalid grammar phrase.");
                commands.Add(normalized, trigger);
            }
        }

        static string Normalize(string text) => string.Join(" ", (text ?? "").ToLowerInvariant()
            .Split((char[])null, StringSplitOptions.RemoveEmptyEntries));

        /// <summary>Pass monotonic seconds. A debounced match is consumed, not retried on a late final.</summary>
        public PhraseTrigger Match(RecognitionPhrase phrase, double now)
        {
            if (double.IsNaN(now) || double.IsInfinity(now)) throw new ArgumentOutOfRangeException(nameof(now));
            if (phrase.UtteranceId < 0) throw new ArgumentOutOfRangeException(nameof(phrase));
            if (phrase.UtteranceId < latest) return PhraseTrigger.None;
            if (phrase.UtteranceId > latest) { latest = phrase.UtteranceId; closed = false; }
            if (closed) return PhraseTrigger.None;
            closed = phrase.IsFinal;
            if (!commands.TryGetValue(Normalize(phrase.Text), out var trigger)) return PhraseTrigger.None;
            closed = true;
            int index = (int)trigger - 1;
            if (now - last[index] < debounce) return PhraseTrigger.None;
            last[index] = now;
            return trigger;
        }
    }
}
