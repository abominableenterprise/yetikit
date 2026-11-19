using System;
using System.Globalization;
using System.Text;

namespace YetiKit.Playtest
{
    /// <summary>
    /// A session's <c>meta.json</c> and the summary numbers for <c>session.done</c>.
    /// </summary>
    public sealed class SessionMeta
    {
        public const int Format = 1;
        public string Session, Player, Build, BuildGuid, AppVersion, Unity, Device, Scene;
        public float RefreshRate;
        public DateTime StartUtc;
        public DateTime? EndUtc;
        public long Frames;      // Unity frames rendered during the session
        public long Samples;     // f lines
        public double HandSeconds, ControllerSeconds, Seconds;
        public int Throws, Errors, Events;
        public long Lost;        // legacy done-marker counter (uncompressed chars)
        public LostRecords LostRange;

        public SessionMeta() { }

        public SessionMeta(string session, ISessionMetadataSource metadata = null, IBuildIdentity build = null,
            IPlayerIdentity player = null)
        {
            Session = session;
            Player = player?.Player;
            Build = build?.Build;
            BuildGuid = build?.BuildGuid;
            AppVersion = build?.AppVersion;
            Unity = metadata?.Unity;
            Device = metadata?.Device;
            Scene = metadata?.Scene;
            RefreshRate = metadata?.RefreshRate ?? 0;
        }

        /// <summary>A snapshot for the pump thread.</summary>
        public SessionMeta Copy() => (SessionMeta)MemberwiseClone();

        public const string UtcFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";

        /// <summary>The meta.json text; <paramref name="counts"/> writes the event counts object (null: <c>{}</c>).</summary>
        public string ToJson(Action<StringBuilder> counts)
        {
            var sb = new StringBuilder(512);
            sb.Append("{\"session\":");
            JsonLine.Str(sb, Session);
            JsonLine.Field(sb, "format", Format);
            JsonLine.Field(sb, "player", Player);
            JsonLine.Field(sb, "build", Build);
            JsonLine.Field(sb, "buildGuid", BuildGuid);
            JsonLine.Field(sb, "version", AppVersion);
            JsonLine.Field(sb, "unity", Unity);
            JsonLine.Field(sb, "device", Device);
            JsonLine.Field(sb, "refreshRate", RefreshRate, 2);
            JsonLine.Field(sb, "scene", Scene);
            JsonLine.Field(sb, "start", Utc(StartUtc));
            JsonLine.Key(sb, "end");
            if (EndUtc.HasValue) JsonLine.Str(sb, Utc(EndUtc.Value));
            else sb.Append("null");
            JsonLine.Field(sb, "seconds", Seconds, 3);
            JsonLine.Field(sb, "frames", Frames);
            JsonLine.Field(sb, "samples", Samples);
            JsonLine.Field(sb, "events", Events);
            JsonLine.Field(sb, "throws", Throws);
            JsonLine.Field(sb, "errors", Errors);
            LostRange.Write(JsonLine.Key(sb, "lost"));
            JsonLine.Field(sb, "handSeconds", HandSeconds, 1);
            JsonLine.Field(sb, "controllerSeconds", ControllerSeconds, 1);
            JsonLine.Key(sb, "counts");
            if (counts != null) counts(sb);
            else sb.Append("{}");
            sb.Append("}\n");
            return sb.ToString();
        }

        public static string Utc(DateTime t) => t.ToUniversalTime().ToString(UtcFormat, CultureInfo.InvariantCulture);

        /// <summary>The completion context numbers for this session.</summary>
        public DoneContext Context() => new DoneContext
        {
            minutes = Round(Seconds / 60.0),
            frames = Frames,
            throws = Throws,
            errors = Errors,
            handMinutes = Round(HandSeconds / 60.0),
            controllerMinutes = Round(ControllerSeconds / 60.0),
            lost = Lost,
        };

        static float Round(double v) => (float)Math.Round(v, 2);
    }

    public interface ISessionMetadataSource
    {
        string Unity { get; }
        string Device { get; }
        string Scene { get; }
        float RefreshRate { get; }
    }

    public interface IBuildIdentity
    {
        string Build { get; }
        string BuildGuid { get; }
        string AppVersion { get; }
    }

    public interface IPlayerIdentity
    {
        string Player { get; }
    }
}
