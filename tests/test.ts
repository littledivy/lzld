#!/usr/bin/env -S deno run -A
import { $ } from "jsr:@david/dax";

await $`cargo build`;

const otool = await $`otool -L target/debug/lzld_tests`.text();
const libs = otool.split("\n").slice(1).map((line) => line.split(" ")[0].trim());

if (libs.length !== 1 || libs[0] !== "/usr/lib/libSystem.B.dylib") {
  throw new Error("Unexpected dependencies: " + libs.join(", "));
}
