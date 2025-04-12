// scripts/deploy.js
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy USDT Mock (สำหรับ test)
  const USDT = await hre.ethers.getContractFactory("MockUSDT");
  const usdt = await USDT.deploy();
  await usdt.deployed();
  console.log("Mock USDT deployed to:", usdt.address);

  // Deploy CryptoMembershipNFT
  const CryptoMembershipNFT = await hre.ethers.getContractFactory("CryptoMembershipNFT");
  const nft = await CryptoMembershipNFT.deploy(usdt.address, deployer.address);
  await nft.deployed();
  console.log("CryptoMembershipNFT deployed to:", nft.address);

  // Verify contracts
  console.log("Waiting for block confirmations...");
  await usdt.deployTransaction.wait(5);
  await nft.deployTransaction.wait(5);
  
  console.log("Verifying contracts...");
  
  try {
    await hre.run("verify:verify", {
      address: usdt.address,
      constructorArguments: [],
    });
    console.log("Mock USDT verified successfully");
  } catch (error) {
    console.error("Error verifying Mock USDT:", error);
  }

  try {
    await hre.run("verify:verify", {
      address: nft.address,
      constructorArguments: [usdt.address, deployer.address],
    });
    console.log("CryptoMembershipNFT verified successfully");
  } catch (error) {
    console.error("Error verifying CryptoMembershipNFT:", error);
  }
  
  console.log("Deployment completed!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });