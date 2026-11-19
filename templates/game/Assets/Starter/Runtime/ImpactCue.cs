using UnityEngine;

namespace Game.Starter
{
    [RequireComponent(typeof(AudioSource))]
    public sealed class ImpactCue : MonoBehaviour
    {
        public void Play()
        {
            var source = GetComponent<AudioSource>();
            if (source.clip) source.PlayOneShot(source.clip);
        }
    }
}
