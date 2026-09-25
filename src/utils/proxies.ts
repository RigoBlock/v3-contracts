import { Contract, getCreate2Address, keccak256, solidityPacked, solidityPackedKeccak256 } from "ethers"

export const calculateProxyAddress = async (factory: Contract, singleton: string, inititalizer: string, nonce: number | string) => {
    const deploymentCode = solidityPacked(["bytes", "uint256"], [await factory.proxyCreationCode.staticCall(), singleton])
    const salt = solidityPackedKeccak256(
        ["bytes32", "uint256"],
        [solidityPackedKeccak256(["bytes"], [inititalizer]), nonce]
    )
    return getCreate2Address(factory.target as string, salt, keccak256(deploymentCode))
}

export const calculateProxyAddressWithCallback = async (factory: Contract, singleton: string, inititalizer: string, nonce: number | string, callback: string) => {
    const saltNonceWithCallback = solidityPackedKeccak256(
        ["uint256", "address"],
        [nonce, callback]
    )
    return calculateProxyAddress(factory, singleton, inititalizer, saltNonceWithCallback)
}
