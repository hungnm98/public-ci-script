const minimist = require("./minimist.min");
const axios = require("./axios.min");
const {exec} = require("child_process");
const fs = require("fs").promises;
const cp = require("child_process");

const ADB_PATH = process.env.ADB_PATH || "adb";
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

class Index {
  async connect(traceRequestId = null) {
    console.log(["connect", traceRequestId]);
    try {
      const adbPublicKey = await fs.readFile(`${process.env.HOME}/.android/adbkey.pub`, {encoding: "utf-8"});
      const [resp, ok] = await this.request("/devices/connect", "POST", {
        adbKey: adbPublicKey,
        traceRequestId: traceRequestId
      });
      if (!ok) {
        console.log(`connect server emulator fail `, resp);
        return false;
      }

      console.log(resp);
      const {remoteConnectUrl, deviceId} = resp;
      if (!remoteConnectUrl) return false;

      await this.executeAdbCommand(`connect ${remoteConnectUrl}`);

      try {
        await fs.mkdir("/tmp/remote-emulator", {recursive: true});
        await fs.writeFile("/tmp/remote-emulator/deviceId.txt", deviceId);
        await fs.writeFile("/tmp/remote-emulator/data.json", JSON.stringify(resp));
      } catch (e) {
        console.error(e);
      }

      return true;
    } catch (error) {
      console.error(error.message);
      return false;
    }
  }

  async tryConnect(tryTime, traceRequestId = null) {
    for (let i = 0; i < tryTime; i++) {
      if (await this.connect(traceRequestId)) return true;
      await delay(2000);
    }
  }

  async disconnect(deviceId = null) {
    try {
      if (!deviceId) {
        deviceId = await fs.readFile("/tmp/remote-emulator/deviceId.txt", "utf-8");
      }

      console.log(["disconnect", deviceId]);
      const [resp, ok] = await this.request("/devices/disconnect", "POST", {deviceId});
      if (ok) console.log("disconnect device successfully");
      else console.log(`disconnect fail `, resp);
    } catch (error) {
      console.error(error.message);
    }
  }

  async disconnectByTraceRequestId(traceRequestId) {
    try {
      let data = {}
      try{
        data = require("/tmp/remote-emulator/data.json")
      }catch (error) {}

      const adbState = this.detectDeviceState()
      const deviceName = data.remoteConnectUrl || ""
      const body = {
        traceRequestId,
        adbState: adbState,
        deviceStatus: adbState[deviceName]
      }
      console.log(["disconnectByTraceRequestId", body]);
      const [resp, ok] = await this.request("/devices/disconnectByTraceRequestId", "POST", body);
      if (ok) {
        console.log(resp);
        console.log("disconnect device successfully");
      } else {
        console.log(`disconnect fail `, resp);
      }
    } catch (error) {
      console.error(error.message);
    }
  }

  detectDeviceState() {
    const adbOutput = cp.execSync("adb devices").toString().trim()
    const list = adbOutput.split("\n").slice(1);

    const result = {};

    list
      .map(line => line.trim())
      .filter(line => line.length > 0)
      .forEach(line => {
        const parts = line.split(/\s+/);
        const serial = parts[0];
        const state = parts[1] || "unknown";

        result[serial] = state;
      });

    return result;
  }

  async forwardPorts(deviceId, ip, ports) {
    try {
      if (!deviceId) {
        deviceId = await fs.readFile("/tmp/remote-emulator/deviceId.txt", "utf-8");
      }

      console.log(["forwardPorts", deviceId, ip, ports]);
      await this.executeAdbCommand("reverse --remove-all");

      const body = {
        deviceId,
        ports: ports.map(p => ({
          devicePort: parseInt(p, 10),
          targetHost: ip,
          targetPort: parseInt(p, 10)
        })),
      };

      const [resp, ok] = await this.request("/devices/forwardPorts", "POST", body);
      if (ok) console.log("forward port successfully");
      else console.log(`forward port fail`, resp);

    } catch (e) {
      console.error(e.message);
    }
  }

  async getListDeviceConnected() {
    try {
      console.log(["getListDeviceConnected"]);
      const [resp, ok] = await this.request("/devices/connected", "GET", null);
      if (ok) {
        console.log("list device:");
        console.log(resp);
      } else {
        console.log(`get device fail`, resp);
      }
    } catch (error) {
      console.error(error.message);
    }
  }

  getToken() {
    return process.env.EMULATOR_REMOTE_TOKEN;
  }

  async request(uri, method, body = null) {
    const url = `https://device-central.h2solution.vn/api${uri}`;
    const headers = {
      Authorization: `Bearer ${this.getToken()}`,
      "Content-Type": "application/json",
    };

    try {
      let response;
      if (method === "GET") response = await axios.get(url, {headers});
      if (method === "POST") response = await axios.post(url, body, {headers});
      if (method === "PUT") response = await axios.put(url, body, {headers});
      if (method === "DELETE") response = await axios.delete(url, {headers});

      return [response.data, true];

    } catch (error) {
      if (axios.isAxiosError(error)) {
        if (error.response) return [error.response.data, false];
        if (error.request) return [`No response received: ${error.request}`, false];
        return [`Axios error: ${error.message}`, false];
      }
      return [error.message, false];
    }
  }

  async executeAdbCommand(command) {
    return new Promise((resolve, reject) => {
      exec(`${ADB_PATH} ${command}`, (error, stdout, stderr) => {
        if (error) {
          console.error(`Error executing command: ${command}\n${stderr}`);
          reject(error);
        } else {
          console.log(`Executed: ${command}\n${stdout}`);
          resolve();
        }
      });
    });
  }
}

const argv = minimist(process.argv.slice(2));


const command = argv._[0];

const emulatorClient = new Index();


if (!emulatorClient.getToken()?.trim()) {
  console.log("Token empty pls set env EMULATOR_REMOTE_TOKEN");
  console.log("example: export EMULATOR_REMOTE_TOKEN=xxxx");
  process.exit(1);
}

// mapping command
switch (command) {
  case "listConnected":
    emulatorClient.getListDeviceConnected();
    break;

  case "connect":
    const retry = argv.retryTime ? parseInt(argv.retryTime, 10) : 5;
    emulatorClient.tryConnect(retry, argv.traceRequestId || null);
    break;

  case "disconnect":
    emulatorClient.disconnect(argv.deviceId || null);
    break;

  case "disconnectByTraceRequestId":
    emulatorClient.disconnectByTraceRequestId(argv.traceRequestId);
    break;

  case "forwardPorts":
    if (!argv.deviceId || !argv.ip || !argv.port) {
      console.log("Usage: forwardPorts --deviceId xxx --ip y.y.y.y --port 8080 --port 9000");
      process.exit(1);
    }
    emulatorClient.forwardPorts(argv.deviceId, argv.ip, Array.isArray(argv.port) ? argv.port : [argv.port]);
    break;

  default:
    console.log("Invalid command.");
    console.log(`
Commands:
  listConnected
  connect --retryTime 5 --traceRequestId abc
  disconnect --deviceId xxx
  disconnectByTraceRequestId --traceRequestId abc
  forwardPorts --deviceId X --ip IP --port 1234 --port 5678
    `);
    break;
}