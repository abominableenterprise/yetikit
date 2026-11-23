#if YETIKIT_VOSK && UNITY_ANDROID
using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using UnityEngine;

namespace YetiKit.Playtest
{
    /// <summary>Android player adapter for the Vosk C API. No Java or managed wrapper required.</summary>
    public sealed class VoskPhraseSpotter : IBlockBoundaryPhraseSpotter
    {
        const string Lib = "vosk";
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr vosk_model_new([MarshalAs(UnmanagedType.LPUTF8Str)] string path);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern void vosk_model_free(IntPtr model);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr vosk_recognizer_new_grm(IntPtr model, float rate, [MarshalAs(UnmanagedType.LPUTF8Str)] string grammar);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern void vosk_recognizer_free(IntPtr recognizer);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int vosk_recognizer_accept_waveform_s(IntPtr recognizer, short[] samples, int count);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr vosk_recognizer_result(IntPtr recognizer);
        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr vosk_recognizer_partial_result(IntPtr recognizer);

        [Serializable] sealed class Result { public string text = ""; public string partial = ""; }
        IntPtr model, recognizer;
        public event Action<string, bool> Phrase;

        public VoskPhraseSpotter(string modelPath, IPhraseGrammar grammar = null)
        {
            if (Application.isEditor) throw new PlatformNotSupportedException("Vosk requires an Android player.");
            var words = new PhraseRules(grammar).Commands.Append("[unk]");
            var json = "[" + string.Join(",", words.Select(p => JsonLine.Str(new StringBuilder(), p).ToString())) + "]";
            model = vosk_model_new(modelPath);
            if (model == IntPtr.Zero) throw new InvalidOperationException("Failed to load the speech model.");
            try
            {
                recognizer = vosk_recognizer_new_grm(model, VoiceActivity.SampleRate, json);
                if (recognizer == IntPtr.Zero) throw new InvalidOperationException("Failed to create the speech recognizer.");
            }
            catch { Dispose(); throw; }
        }

        public void Accept(short[] pcm, int count)
        {
            if (recognizer == IntPtr.Zero) throw new ObjectDisposedException(nameof(VoskPhraseSpotter));
            if (pcm == null) throw new ArgumentNullException(nameof(pcm));
            if (count < 0 || count > pcm.Length) throw new ArgumentOutOfRangeException(nameof(count));
            int status = vosk_recognizer_accept_waveform_s(recognizer, pcm, count);
            if (status < 0) throw new InvalidOperationException("Speech recognition failed.");
            bool final = status != 0;
            var ptr = final ? vosk_recognizer_result(recognizer) : vosk_recognizer_partial_result(recognizer);
            var result = JsonUtility.FromJson<Result>(Marshal.PtrToStringUTF8(ptr));
            var text = (final ? result?.text : result?.partial) ?? "";
            if (final || text.Length != 0) Phrase?.Invoke(text, final);
        }

        public void Dispose()
        {
            if (recognizer != IntPtr.Zero) { vosk_recognizer_free(recognizer); recognizer = IntPtr.Zero; }
            if (model != IntPtr.Zero) { vosk_model_free(model); model = IntPtr.Zero; }
        }
    }
}
#endif
