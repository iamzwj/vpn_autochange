import fs from "node:fs";
import path from "node:path";

const iconset = process.argv[2];
const output = process.argv[3];

if (!iconset || !output) {
  throw new Error("Usage: node make-icon.mjs <iconset> <output.icns>");
}

const entries = [
  ["ic10", "icon_512x512@2x.png"],
  ["ic09", "icon_256x256@2x.png"],
  ["ic08", "icon_128x128@2x.png"],
  ["ic07", "icon_128x128.png"],
  ["icp6", "icon_32x32@2x.png"],
  ["icp5", "icon_32x32.png"],
  ["icp4", "icon_16x16.png"],
].map(([type, file]) => {
  const image = fs.readFileSync(path.join(iconset, file));
  const header = Buffer.alloc(8);
  header.write(type, 0, 4, "ascii");
  header.writeUInt32BE(image.length + 8, 4);
  return Buffer.concat([header, image]);
});

const body = Buffer.concat(entries);
const header = Buffer.alloc(8);
header.write("icns", 0, 4, "ascii");
header.writeUInt32BE(body.length + 8, 4);
fs.writeFileSync(output, Buffer.concat([header, body]));
