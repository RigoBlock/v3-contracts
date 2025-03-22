// we also add null fee amount for testing
const FEE_SIZE = 3

export function encodePath(path: string[], fees: FeeAmount[]): string {
  if (path.length != fees.length + 1) {
    throw new Error('path/fee lengths do not match')
  }

  let encoded = '0x'
  for (let i = 0; i < fees.length; i++) {
    // 20 byte encoding of the address
    encoded += path[i].slice(2)
    // 3 byte encoding of the fee
    encoded += fees[i].toString(16).padStart(2 * FEE_SIZE, '0')
  }
  // encode the final token
  encoded += path[path.length - 1].slice(2)

  return encoded.toLowerCase()
}

export enum FeeAmount {
    LOW = 500,
    MEDIUM = 3000,
    HIGH = 10000
}

export const encodeMultihopExactInPath = (poolKeys: any[], currencyIn: string): any[] => {
  let pathKeys: { intermediateCurrency: any; fee: any; tickSpacing: any; hooks: any; hookData: string; }[] = []
  for (let i = 0; i < poolKeys.length; i++) {
    let currencyOut = currencyIn == poolKeys[i].currency0 ? poolKeys[i].currency1 : poolKeys[i].currency0
    let pathKey = {
      intermediateCurrency: currencyOut,
      fee: poolKeys[i].fee,
      tickSpacing: poolKeys[i].tickSpacing,
      hooks: poolKeys[i].hooks,
      hookData: '0x',
    }
    pathKeys.push(pathKey)
    currencyIn = currencyOut
  }
  return pathKeys
}
