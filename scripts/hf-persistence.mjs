import fs from "node:fs";
import path from "node:path";

const DATA_DIR = process.env.DATA_DIR || "/app/data";
const DB_PATH = path.join(DATA_DIR, "storage.sqlite");

const HF_TOKEN = process.env.HF_TOKEN;
const HF_BUCKET = process.env.HF_BUCKET || "hfdevhere/omniroute";

if (!HF_TOKEN) {
  console.log("[HF] HF_TOKEN not configured; persistence disabled.");
  process.exit(0);
}

const [owner, bucket] = HF_BUCKET.split("/");

if (!owner || !bucket) {
  throw new Error(
    `Invalid HF_BUCKET: ${HF_BUCKET}. Expected owner/bucket`
  );
}

const API_BASE =
  `https://huggingface.co/api/buckets/${owner}/${bucket}`;

async function downloadDatabase() {
  console.log(`[HF] Checking bucket ${HF_BUCKET}...`);

  const response = await fetch(
    `${API_BASE}/resolve/main/storage.sqlite`,
    {
      headers: {
        Authorization: `Bearer ${HF_TOKEN}`,
      },
    }
  );

  if (response.status === 404) {
    console.log("[HF] No database exists yet.");
    return false;
  }

  if (!response.ok) {
    throw new Error(
      `HF download failed: ${response.status} ${await response.text()}`
    );
  }

  const buffer = Buffer.from(await response.arrayBuffer());

  fs.mkdirSync(DATA_DIR, { recursive: true });

  fs.writeFileSync(DB_PATH, buffer);

  console.log(
    `[HF] Database restored: ${(buffer.length / 1024 / 1024).toFixed(2)} MB`
  );

  return true;
}

async function uploadDatabase() {
  if (!fs.existsSync(DB_PATH)) {
    console.log("[HF] Database doesn't exist yet.");
    return;
  }

  console.log("[HF] Uploading database...");

  const file = fs.readFileSync(DB_PATH);

  const response = await fetch(
    `${API_BASE}/upload/main/storage.sqlite`,
    {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${HF_TOKEN}`,
        "Content-Type": "application/octet-stream",
      },
      body: file,
    }
  );

  if (!response.ok) {
    throw new Error(
      `HF upload failed: ${response.status} ${await response.text()}`
    );
  }

  console.log(
    `[HF] Database uploaded: ${(file.length / 1024 / 1024).toFixed(2)} MB`
  );
}

const command = process.argv[2];

if (command === "restore") {
  await downloadDatabase();
} else if (command === "backup") {
  await uploadDatabase();
} else {
  console.log("Usage:");
  console.log("  node scripts/hf-persistence.mjs restore");
  console.log("  node scripts/hf-persistence.mjs backup");
}