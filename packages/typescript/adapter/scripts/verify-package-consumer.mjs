// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const consumerDirectory = resolve(packageDirectory, ".package-consumer");
const typeScriptCompiler = resolve(
  packageDirectory,
  "node_modules",
  "typescript",
  "bin",
  "tsc"
);

function run(command, arguments_, cwd) {
  execFileSync(command, arguments_, { cwd, stdio: "inherit" });
}

function pack() {
  const output = execFileSync("npm", ["pack", "--json"], {
    cwd: packageDirectory,
    encoding: "utf8",
  });
  const packages = JSON.parse(output);
  const tarballName = packages[0]?.filename;

  if (typeof tarballName !== "string") {
    throw new Error("npm pack --json did not return a tarball filename");
  }

  return resolve(packageDirectory, tarballName);
}

function initializeConsumer() {
  rmSync(consumerDirectory, { recursive: true, force: true });
  mkdirSync(consumerDirectory, { recursive: true });
  writeFileSync(
    resolve(consumerDirectory, "package.json"),
    `${JSON.stringify({ private: true, type: "module" }, null, 2)}\n`
  );
  writeFileSync(
    resolve(consumerDirectory, "tsconfig.json"),
    `${JSON.stringify(
      {
        compilerOptions: {
          module: "NodeNext",
          moduleResolution: "NodeNext",
          strict: true,
        },
      },
      null,
      2
    )}\n`
  );
  writeFileSync(
    resolve(consumerDirectory, "typecheck.ts"),
    'import { immediateOf, io, requestOf } from "necoherence";\n\nconst greet = immediateOf<{ name: string }, string>("consumer.greet", ["name"], ({ name }) => `hello ${name}`);\nconst result = io(greet, requestOf({ name: "consumer" }, ["name"]));\nif (result.tag === "Ok") {\n  const value: string = result.value;\n  void value;\n}\n'
  );
}

let tarballPath;

try {
  run("npm", ["run", "build"], packageDirectory);
  tarballPath = pack();
  initializeConsumer();
  run(
    "npm",
    [
      "install",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      "--no-package-lock",
      "--offline",
      tarballPath,
    ],
    consumerDirectory
  );
  run(
    "node",
    [
      "--input-type=module",
      "--eval",
      'import { immediateOf, io, requestOf } from "necoherence"; const greet = immediateOf("consumer.greet", ["name"], ({ name }) => `hello ${name}`); const result = io(greet, requestOf({ name: "consumer" }, ["name"])); if (result.tag !== "Ok" || result.value !== "hello consumer") throw new Error("root import failed");',
    ],
    consumerDirectory
  );
  run("node", [typeScriptCompiler, "--noEmit"], consumerDirectory);
} finally {
  rmSync(consumerDirectory, { recursive: true, force: true });
  if (tarballPath !== undefined && existsSync(tarballPath)) {
    rmSync(tarballPath, { force: true });
  }
}
