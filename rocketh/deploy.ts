import {setupDeployScripts} from "rocketh";
import type {Accounts, Data, Extensions} from "./config.js";
import {extensions} from "./config.js";

const {deployScript} = setupDeployScripts<Extensions, Accounts, Data>(extensions);

export {deployScript};
