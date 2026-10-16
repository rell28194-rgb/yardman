"""Create stable Unity asset GUIDs before the first Editor import; preserve existing GUIDs."""
from pathlib import Path
import uuid

root = Path(__file__).resolve().parent.parent
for path in sorted((root / "Assets").rglob("*")):
    if path.name.endswith(".meta"):
        continue
    meta = Path(str(path) + ".meta")
    if meta.exists():
        continue
    guid = uuid.uuid5(uuid.NAMESPACE_URL, "yardman:" + path.relative_to(root).as_posix()).hex
    result = "fileFormatVersion: 2\nguid: " + guid + "\n"
    if path.is_dir():
        result += "folderAsset: yes\nDefaultImporter:\n  externalObjects: {}\n"
    elif path.suffix == ".cs":
        result += "MonoImporter:\n  externalObjects: {}\n  serializedVersion: 2\n  defaultReferences: []\n  executionOrder: 0\n  icon: {instanceID: 0}\n"
    elif path.suffix == ".asmdef":
        result += "AssemblyDefinitionImporter:\n  externalObjects: {}\n"
    elif path.suffix == ".json":
        result += "TextScriptImporter:\n  externalObjects: {}\n"
    else:
        result += "DefaultImporter:\n  externalObjects: {}\n"
    meta.write_text(result + "  userData:\n  assetBundleName:\n  assetBundleVariant:\n")
