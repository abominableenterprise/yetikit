namespace YetiKit.Lab
{
    /// <summary>Receives the active selection. Consumers own controls and scene routing.</summary>
    public interface IExperimentSelectionView
    {
        void ShowSelection(string id, string help);
    }
}
