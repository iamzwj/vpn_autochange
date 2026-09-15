import fs from "node:fs";
import http from "node:http";

const configPath =
  "/Users/wwwj/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml";
const config = fs.readFileSync(configPath, "utf8");
const socketPath =
  config.match(/^external-controller-unix:\s*(.+)$/m)?.[1]?.trim() ||
  "/tmp/verge/verge-mihomo.sock";
let secret = config.match(/^secret:\s*(.*)$/m)?.[1]?.trim() || "";
secret = secret.replace(/^['"]|['"]$/g, "");

function request(path) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        socketPath,
        path,
        method: "GET",
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${secret}`,
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          resolve({
            status: res.statusCode,
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      },
    );
    req.on("error", reject);
    req.end();
  });
}

const all = await request("/proxies");
let groupNames = [];
let taiwanCandidates = [];
if (all.status === 200) {
  const parsed = JSON.parse(all.body);
  groupNames = Object.entries(parsed.proxies || {})
    .filter(([, proxy]) => Array.isArray(proxy.all))
    .map(([name]) => name);
  const mainGroup =
    parsed.proxies?.["节点选择"] ||
    parsed.proxies?.Proxies ||
    parsed.proxies?.GLOBAL;
  taiwanCandidates = (mainGroup?.all || []).filter((name) =>
    name.includes("台湾"),
  );
}

const direct = await request("/proxies/Proxies");
console.log(
  JSON.stringify({
    socketExists: fs.existsSync(socketPath),
    allStatus: all.status,
    directStatus: direct.status,
    groupNames,
    taiwanCandidateCount: taiwanCandidates.length,
    taiwanCandidates,
  }),
);
