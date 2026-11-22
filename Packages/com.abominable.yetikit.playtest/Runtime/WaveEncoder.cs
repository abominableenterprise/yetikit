using System;
using System.IO;

namespace YetiKit.Playtest
{
    /// <summary>Encodes 16 kHz mono PCM16 as little-endian RIFF/WAVE.</summary>
    public static class WaveEncoder
    {
        public static byte[] Encode(short[] pcm) => Encode(pcm, 0, pcm?.Length ?? 0);
        public static byte[] Encode(short[] pcm, int offset, int count)
        {
            VoiceActivity.ValidateSlice(pcm, offset, count);
            if (count > (int.MaxValue - 44) / 2) throw new ArgumentOutOfRangeException(nameof(count));
            int bytes = count * 2;
            var wav = new byte[44 + bytes];
            using var writer = new BinaryWriter(new MemoryStream(wav));
            writer.Write(0x46464952); // RIFF
            writer.Write(36 + bytes);
            writer.Write(0x45564157); // WAVE
            writer.Write(0x20746d66); // fmt
            writer.Write(16);
            writer.Write(0x00010001); // PCM, mono
            writer.Write(VoiceActivity.SampleRate);
            writer.Write(VoiceActivity.SampleRate * 2);
            writer.Write(0x00100002); // two bytes per sample frame, 16 bits per sample
            writer.Write(0x61746164); // data
            writer.Write(bytes);
            for (int i = 0; i < count; i++) writer.Write(pcm[offset + i]);
            return wav;
        }
    }
}
