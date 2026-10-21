import json
import pathlib
from PIL import Image, ImageDraw

root = pathlib.Path(__file__).resolve().parents[1] / "App" / "Assets.xcassets"
catalog = root / "AppIcon.appiconset"
catalog.mkdir(parents=True, exist_ok=True)
canvas = Image.new("RGB", (1024, 1024), "#28244C")
draw = ImageDraw.Draw(canvas)
draw.rounded_rectangle((157, 169, 867, 804), radius=150, fill="#DCDFF4")
draw.polygon([(275, 720), (275, 891), (472, 743)], fill="#DCDFF4")
draw.rounded_rectangle((225, 237, 799, 667), radius=96, fill="#5046C7")
draw.polygon([(225, 594), (415, 401), (603, 603), (700, 497), (799, 602), (799, 667), (225, 667)], fill="#A8B1E0")
draw.ellipse((629, 291, 729, 391), fill="#FAF7ED")
draw.line([(257, 745), (527, 745)], fill="#5046C7", width=22)
entries = []
for idiom, points, scales in [
    ("iphone", 20, [2, 3]), ("iphone", 29, [2, 3]),
    ("iphone", 40, [2, 3]), ("iphone", 60, [2, 3]),
    ("ipad", 20, [1, 2]), ("ipad", 29, [1, 2]),
    ("ipad", 40, [1, 2]), ("ipad", 76, [1, 2]), ("ipad", 83.5, [2]),
    ("ios-marketing", 1024, [1]),
]:
    for scale in scales:
        pixels = int(points * scale)
        filename = f"icon-{pixels}.png"
        canvas.resize((pixels, pixels), Image.Resampling.LANCZOS).save(catalog / filename)
        entries.append({"idiom": idiom, "size": f"{points}x{points}", "scale": f"{scale}x", "filename": filename})
(catalog / "Contents.json").write_text(json.dumps({"images": entries, "info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")
(root / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}), encoding="utf-8")
print(f"Generated {len(entries)} icon slots in {catalog}")
