using System;
using System.Collections.Generic;
using System.Threading;

namespace YetiKit.Playtest
{
    public readonly struct RecognitionPhrase
    {
        public readonly string Text;
        public readonly bool IsFinal;
        public readonly long UtteranceId, SamplesProcessed;
        /// <summary>Absolute PCM sample offset, or -1 if no initial quiet boundary was observed.</summary>
        public readonly long OnsetSample;
        /// <summary>Exclusive end of the last voiced VAD frame for this utterance, or -1 if unobserved
        /// or the spotter does not guarantee block-aligned endpoints. Use the matching final to refine the estimate.</summary>
        public readonly long EndSample;

        public RecognitionPhrase(string text, bool isFinal, long utteranceId, long onsetSample, long samplesProcessed)
            : this(text, isFinal, utteranceId, onsetSample, samplesProcessed, -1) { }

        public RecognitionPhrase(string text, bool isFinal, long utteranceId, long onsetSample, long samplesProcessed, long endSample)
        {
            Text = text;
            IsFinal = isFinal;
            UtteranceId = utteranceId;
            OnsetSample = onsetSample;
            SamplesProcessed = samplesProcessed;
            EndSample = endSample;
        }
    }

    /// <summary>Runs recognition, callbacks and spotter disposal on a background thread.</summary>
    public sealed class RecognitionWorker : IDisposable
    {
        readonly IPhraseSpotter spotter;
        readonly bool hasBlockBounds;
        readonly Queue<short[]> audio = new Queue<short[]>();
        readonly object gate = new object();
        readonly VoiceActivity vad = new VoiceActivity();
        readonly Thread thread;
        bool stopping, onsetLatched;
        int queuedSamples;
        long utteranceId, onset = -1, end = -1;
        volatile Exception failure;
        public event Action<RecognitionPhrase> Phrase;
        public Exception Failure => failure;

        public RecognitionWorker(IPhraseSpotter spotter)
        {
            this.spotter = spotter ?? throw new ArgumentNullException(nameof(spotter));
            hasBlockBounds = spotter is IBlockBoundaryPhraseSpotter;
            thread = new Thread(Run) { IsBackground = true };
            thread.Start();
        }

        /// <summary>Copies consecutive PCM, starting at sample zero. On backpressure, retry the
        /// same block before submitting later samples, or restart the stream; don't skip a block.</summary>
        public bool TryEnqueue(short[] pcm)
        {
            if (pcm == null) throw new ArgumentNullException(nameof(pcm));
            lock (gate)
            {
                if (stopping || pcm.Length == 0 || pcm.Length > 2 * VoiceActivity.SampleRate - queuedSamples) return false;
                audio.Enqueue((short[])pcm.Clone());
                queuedSamples += pcm.Length;
                Monitor.Pulse(gate);
                return true;
            }
        }

        /// <summary>Discards queued audio. On timeout, the worker still owns the in-flight call and disposal.</summary>
        public bool Stop(int milliseconds = 200)
        {
            if (milliseconds < 0) throw new ArgumentOutOfRangeException(nameof(milliseconds));
            Cancel();
            return Thread.CurrentThread != thread && thread.Join(milliseconds);
        }

        public void Dispose() => Stop();
        void Cancel() { lock (gate) { stopping = true; audio.Clear(); Monitor.Pulse(gate); } }
        void Run()
        {
            try
            {
                spotter.Phrase += OnPhrase;
                while (true)
                {
                    short[] block;
                    lock (gate)
                    {
                        while (!stopping && audio.Count == 0) Monitor.Wait(gate);
                        if (stopping) return;
                        block = audio.Dequeue();
                        queuedSamples -= block.Length;
                    }
                    var voiced = vad.Process(block, 0, block.Length, out var boundary);
                    if (voiced)
                    {
                        if (!onsetLatched) { onset = boundary; onsetLatched = true; }
                        end = vad.LastVoicedEndSample;
                    }
                    spotter.Accept(block, block.Length);
                }
            }
            catch (Exception e) { failure = e; }
            finally
            {
                Cancel();
                try { try { spotter.Phrase -= OnPhrase; } finally { spotter.Dispose(); } }
                catch (Exception e) { failure = failure ?? e; }
            }
        }

        void OnPhrase(string text, bool final)
        {
            var phrase = new RecognitionPhrase(text, final, utteranceId, onset, vad.SamplesProcessed, hasBlockBounds ? end : -1);
            if (!string.IsNullOrEmpty(text)) onsetLatched = true;
            if (final) { utteranceId++; onset = end = -1; onsetLatched = false; }
            Phrase?.Invoke(phrase);
        }
    }
}
