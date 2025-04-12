// test/CryptoMembershipNFT.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CryptoMembershipNFT", function () {
  let nft;
  let usdt;
  let owner;
  let addr1;
  let addr2;

  beforeEach(async function () {
    [owner, addr1, addr2] = await ethers.getSigners();

    // Deploy mock USDT
    const USDT = await ethers.getContractFactory("MockUSDT");
    usdt = await USDT.deploy();
    await usdt.deployed();

    // Deploy NFT contract
    const CryptoMembershipNFT = await ethers.getContractFactory("CryptoMembershipNFT");
    nft = await CryptoMembershipNFT.deploy(usdt.address, owner.address);
    await nft.deployed();
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await nft.owner()).to.equal(owner.address);
    });
  });
});