using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.PackageManager.UI;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.XR.Interaction.Toolkit.Inputs;

namespace Game.Starter.Editor
{
    public static class StarterControllerSample
    {
        const string Package = "com.unity.xr.interaction.toolkit";
        const string SampleName = "Starter Assets";
        const string LeftPrefab = "Prefabs/Controllers/XR Controller Left.prefab";
        const string RightPrefab = "Prefabs/Controllers/XR Controller Right.prefab";
        const string Actions = "XRI Default Input Actions.inputactions";
        const string Mesh = "Models/UniversalController.fbx";
        const string Animator = "Scripts/ControllerAnimator.cs";
        static readonly string[] Files =
        {
            LeftPrefab, RightPrefab, Actions, Mesh, Animator,
            "Materials/Controller_White.mat", "Materials/Controller_Grey.mat", "Textures/DefaultMaterial_AO.png",
        };

        // The full demo's assemblies reference OpenXR and the demo uses Shader Graph. Neither is
        // required for these prefabs. Import their dependency set without adding packages or
        // changing vendor files; retain the upstream metas for prefab, mesh and action references.
        // A true return means callers must wait for Unity to compile ControllerAnimator before baking.
        public static bool Import()
        {
            var sample = FindSample();
            if (Files.All(file => Exists(sample.importPath, file))) return false;
            if (Directory.Exists(sample.importPath) || !Files.All(file => Exists(sample.resolvedPath, file)))
                throw Unavailable();

            var staging = Path.GetFullPath(Path.Combine("Temp", $"StarterControllers-{Guid.NewGuid():N}"));
            try
            {
                foreach (var file in Files)
                {
                    var destination = Path.Combine(staging, file);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination));
                    File.Copy(Path.Combine(sample.resolvedPath, file), destination);
                    File.Copy(Path.Combine(sample.resolvedPath, file + ".meta"), destination + ".meta");
                }
                Directory.CreateDirectory(Path.GetDirectoryName(sample.importPath));
                Directory.Move(staging, sample.importPath);
            }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException)
            {
                throw Unavailable(error);
            }
            finally
            {
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
            }
            AssetDatabase.Refresh();
            return true;
        }

        internal static (GameObject left, GameObject right, InputActionAsset actions) Load()
        {
            var sample = FindSample();
            if (!Files.All(file => Exists(sample.importPath, file))) throw Unavailable();
            var path = "Assets/" + Path.GetRelativePath(Application.dataPath, sample.importPath).Replace('\\', '/');
            var left = AssetDatabase.LoadAssetAtPath<GameObject>($"{path}/{LeftPrefab}");
            var right = AssetDatabase.LoadAssetAtPath<GameObject>($"{path}/{RightPrefab}");
            var actions = AssetDatabase.LoadAssetAtPath<InputActionAsset>($"{path}/{Actions}");
            var animator = AssetDatabase.LoadAssetAtPath<MonoScript>($"{path}/{Animator}")?.GetClass();
            if (!left || !right || !actions || animator == null || !left.GetComponent(animator) || !right.GetComponent(animator))
                throw Unavailable();
            return (left, right, actions);
        }

        internal static void AddInput(GameObject rig, InputActionAsset actions)
        {
            // The prefab readers use references, which don't enable actions themselves.
            rig.AddComponent<InputActionManager>().actionAssets = new List<InputActionAsset> { actions };
        }

        static Sample FindSample()
        {
            var sample = Sample.FindByPackage(Package, null).FirstOrDefault(item => item.displayName == SampleName);
            if (string.IsNullOrEmpty(sample.resolvedPath)) throw Unavailable();
            return sample;
        }

        static bool Exists(string folder, string file) =>
            File.Exists(Path.Combine(folder, file)) && File.Exists(Path.Combine(folder, file + ".meta"));

        static InvalidOperationException Unavailable(Exception cause = null) => new(
            "XR Interaction Toolkit Starter Assets controllers are unavailable. Restore the pinned package, " +
            "move an incomplete Starter Assets import out of Assets/Samples, then run Game > Build Starter Sandbox " +
            "to import the controller assets. For scripted bakes, call StarterControllerSample.Import() and wait for script compilation first.", cause);
    }
}
