import fs from "fs";
import {task} from "hardhat/config";
import {ArgumentType} from "hardhat/types/arguments";
import type {NewTaskDefinition} from "hardhat/types/tasks";
import {loadSolc} from "../utils/solc";

export const codesizeTask: NewTaskDefinition = task(
  "codesize",
  "Displays the codesize of the contracts",
)
  .addOption({
    name: "skipcompile",
    type: ArgumentType.BOOLEAN,
    description: "should not compile before printing size",
    defaultValue: false,
  })
  .addOption({
    name: "contractname",
    type: ArgumentType.STRING_WITHOUT_DEFAULT,
    description: "name of the contract",
    defaultValue: undefined,
  })
  .setInlineAction(async (taskArgs, hre) => {
    if (!taskArgs.skipcompile) {
      await hre.tasks.getTask("compile").run({});
    }
    const contracts = await hre.artifacts.getAllFullyQualifiedNames();
    for (const contract of contracts) {
      const artifact = await hre.artifacts.readArtifact(contract);
      if (taskArgs.contractname && taskArgs.contractname !== artifact.contractName)
        continue;
      console.log(
        artifact.contractName,
        Math.max(0, (artifact.deployedBytecode.length - 2) / 2),
        "bytes (limit is 24576)",
      );
    }
  })
  .build();

export const yulcodeTask: NewTaskDefinition = task(
  "yulcode",
  "Outputs yul code for contracts",
)
  .addOption({
    name: "contractname",
    type: ArgumentType.STRING_WITHOUT_DEFAULT,
    description: "name of the contract",
    defaultValue: undefined,
  })
  .setInlineAction(async (taskArgs, hre) => {
    const contracts = await hre.artifacts.getAllFullyQualifiedNames();
    for (const contract of contracts) {
      if (taskArgs.contractname && !contract.endsWith(taskArgs.contractname))
        continue;
      const buildInfoId = await hre.artifacts.getBuildInfoId(contract);
      if (!buildInfoId) return;
      const buildInfoPath = await hre.artifacts.getBuildInfoPath(buildInfoId);
      if (!buildInfoPath) return;
      const buildInfo = JSON.parse(fs.readFileSync(buildInfoPath, "utf8"));
      console.log({buildInfo});
      buildInfo.input.settings.outputSelection["*"]["*"].push(
        "ir",
        "evm.assembly",
      );
      const solcjs = await loadSolc(buildInfo.solcLongVersion);
      const compiled = solcjs.compile(JSON.stringify(buildInfo.input));
      const output = JSON.parse(compiled);
      console.log(output.contracts[contract.split(":")[0]]);
      console.log(output.errors);
    }
  })
  .build();
