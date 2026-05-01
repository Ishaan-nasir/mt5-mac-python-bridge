# MT5-Mac-Python-Bridge

## The OS Limitation
The official `MetaTrader5` Python library is built around a tight integration with Windows C++ DLLs. Because of this architectural dependency, developers building AI bots or quantitative trading scripts on macOS or Linux physically cannot connect Python to MT5 locally using the official library. It will throw instant OS-compatibility exceptions.

## Why I Built This
To circumvent this hard constraint without renting a Windows VPS or dealing with complicated Wine setups, I engineered a **local HTTP bridge**. This architecture cleanly decouples the Python algorithmic engine from the MT5 execution terminal. 

By treating MT5 as a dummy execution node and Python as the brain, Mac and Linux developers can freely build, test, and deploy complex institutional-grade Python algorithms locally. 

## File Breakdown

### 1. `fastapi_bridge.py` (The Brain)
A lightweight FastAPI server running natively on your Mac (localhost:8000). It acts as the central hub:
- **Receives Market Data**: Accepts high-frequency tick data POSTed by MT5.
- **Executes Logic**: Processes incoming data through your AI/algorithmic models.
- **Dispatches Commands**: Queues execution commands (LONG, SHORT, MODIFY, CLOSE) which are pulled by MT5.

### 2. `MT5_Web_Bridge.mq5` (The Execution Terminal)
A custom MQL5 Expert Advisor (EA) designed to run inside MT5. It is essentially a headless dummy terminal that:
- **Polls the Server**: Uses native `WebRequest` to ping the Python FastAPI server every 500ms.
- **Pushes State**: Sends the latest bid/ask, open positions, and account state to Python.
- **Executes JSON**: Receives JSON execution commands from Python and fires them directly into the broker's matching engine.

---

## Step 1: Python Setup
To run the server on your Mac, you need Python installed. 

1. Install the required dependencies in your terminal:
   ```bash
   pip install fastapi uvicorn pydantic
   ```
2. Start the FastAPI server:
   ```bash
   python3 fastapi_bridge.py
   ```
   *You should see output indicating the server is running on `0.0.0.0:8000`.*

---

## Step 2: MetaTrader 5 Setup (Crucial)
To allow the MQL5 EA to communicate with your local Python server, you must explicitly whitelist the URL in MT5.

1. Open MetaTrader 5 and launch **MetaEditor** (F4).
2. Drag or paste the `MT5_Web_Bridge.mq5` file into your `MQL5/Experts` directory in the Navigator window.
3. Open the file and **Compile** the EA (F7).
4. In the main MT5 terminal, navigate to **Tools -> Options** (Cmd+O or Ctrl+O).
5. Go to the **Expert Advisors** tab.
6. Check the box for **"Allow WebRequests for listed URL"**.
7. Double-click the `+` icon and explicitly add your local server URL: 
   ```text
   http://127.0.0.1:8000
   ```
   *(If you are running the Python server on a different local IP, add that instead).*
8. Drag and drop the compiled `MT5_Web_Bridge` EA onto any active chart. Ensure the "Allow Auto Trading" (Algo Trading) button is enabled in the top toolbar.

The bridge is now established. Your MT5 terminal will begin polling data to your Python server, and your Python algorithms can now execute trades instantly on your Mac.
