// Narrow declaration for the single Node test-artifact API used here.
// Application code does not depend on Node globals or filesystem APIs.
declare module "node:fs/promises" {
  export function writeFile(path: string, data: string): Promise<void>;
}
