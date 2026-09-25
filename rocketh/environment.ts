import {setupEnvironmentFromFiles} from "@rocketh/node";
import {setupHardhatDeploy} from "hardhat-deploy/helpers";
import type {Accounts, Data, Extensions} from "./config.js";
import {extensions} from "./config.js";

// Used by tests: runs the deploy scripts against an in-memory provider (with caching
// via hardhat-network-helpers' loadFixture) and by tasks that need the deployment set.
const {loadAndExecuteDeploymentsFromFiles, loadEnvironmentFromFiles} =
  setupEnvironmentFromFiles<Extensions, Accounts, Data>(extensions);
const {loadEnvironmentFromHardhat} = setupHardhatDeploy<Extensions, Accounts, Data>(extensions);

export {loadEnvironmentFromHardhat, loadEnvironmentFromFiles, loadAndExecuteDeploymentsFromFiles};
