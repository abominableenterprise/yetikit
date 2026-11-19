namespace YetiKit.Lab
{
    public interface ITuningBinding
    {
        string Id { get; }
        string Group { get; }
        float Default { get; }
        float Min { get; }
        float Max { get; }
        float Step { get; }
        bool IsBool { get; }
        float Get();
        void Set(float value);
    }
}
