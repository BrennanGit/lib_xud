// Copyright 2011-2022 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.

/**
  * @file      XUD_Main.xc
  * @brief     XMOS USB Device (XUD) Layer
  * @author    Ross Owen
  **/
#include <xs1.h>
#include <print.h>
#include <xclib.h>
#include <platform.h>

#include "xud.h"                 /* External user include file */
#include "XUD_USB_Defines.h"
#include "XUD_Support.h"

#include "XUD_DeviceAttach.h"
#include "XUD_Signalling.h"
#include "XUD_HAL.h"
#include "XUD_TimingDefines.h"

#if (USB_MAX_NUM_EP_IN != 16)
#error USB_MAX_NUM_EP_IN must be 16!
#endif
#if (USB_MAX_NUM_EP_OUT != 16)
#error USB_MAX_NUM_EP_OUT must be 16!
#endif

void XUD_UserSuspend();
void XUD_UserResume();
void XUD_PhyReset_User();

#define HS_TX_HANDSHAKE_TIMEOUT (167)
#define FS_TX_HANDSHAKE_TIMEOUT (5000)

/* Global vars for current and desired USB speed */
unsigned g_curSpeed;
unsigned g_desSpeed;
unsigned g_txHandshakeTimeout;

in port flag0_port = PORT_USB_FLAG0; /* For XS3: Mission: RXE, XS2 is configurable and set to RXE in mission mode */
in port flag1_port = PORT_USB_FLAG1; /* For XS3: Mission: RXA, XS2 is configuratble and set to RXA in mission mode*/

/* XS2A has an additonal flag port. In Mission mode this is set to VALID_TOKEN */
#ifdef __XS2A__
in port flag2_port = PORT_USB_FLAG2;
#else
#define flag2_port null
#endif

in buffered port:32 p_usb_clk  = PORT_USB_CLK;
out buffered port:32 p_usb_txd = PORT_USB_TXD;
in  buffered port:32 p_usb_rxd = PORT_USB_RXD;
out port tx_readyout           = PORT_USB_TX_READYOUT;
in port tx_readyin             = PORT_USB_TX_READYIN;
in port rx_rdy                 = PORT_USB_RX_READY;

on USB_TILE: clock tx_usb_clk  = XS1_CLKBLK_4;
on USB_TILE: clock rx_usb_clk  = XS1_CLKBLK_5;

XUD_chan epChans[USB_MAX_NUM_EP];
XUD_chan epChans0[USB_MAX_NUM_EP];

XUD_ep_info ep_info[USB_MAX_NUM_EP];

/* Location to store stack pointer (required for interrupt handler) */
unsigned SavedSp;

/* Tables storing if EP's are signed up to bus state updates */
int epStatFlagTableIn[USB_MAX_NUM_EP_IN];
int epStatFlagTableOut[USB_MAX_NUM_EP_OUT];

extern unsigned XUD_LLD_IoLoop(
                            in buffered port:32 rxd_port,
                            in port rxa_port,
                            out buffered port:32 txd_port,
                            in port rxe_port, in port ?valtok_port,
                            XUD_EpType epTypeTableOut[], XUD_EpType epTypeTableIn[], XUD_chan epChans[],
                            int  epCount, chanend? c_sof) ;

unsigned ep_addr[USB_MAX_NUM_EP];

unsigned sentReset=0;

unsigned crcmask = 0b11111111111;
unsigned chanArray;

#define RESET_TIME_us               (5)
#define RESET_TIME                  (RESET_TIME_us * REF_CLK_FREQ)

#if (XUD_OPT_SOFTCRC5 == 1)
extern unsigned char crc5Table[2048];
extern unsigned char crc5Table_Addr[2048];

void XUD_SetCrcTableAddr(unsigned addr);
#endif

static int one = 1;

#pragma unsafe arrays
static void SendResetToEps(XUD_chan c[], XUD_chan epChans[], XUD_EpType epTypeTableOut[], XUD_EpType epTypeTableIn[], int nOut, int nIn, int token)
{
    for(int i = 0; i < nOut; i++)
    {
        if(epTypeTableOut[i] != XUD_EPTYPE_DIS && epStatFlagTableOut[i])
        {
            /* Set EP resetting flag. EP uses this to check if it missed a reset before setting ready */
            ep_info[i].resetting = 1;

            /* Clear EP ready. Note. small race since EP might set ready after XUD sets resetting to 1
             * but this should be caught in time (EP gets CT) */
            epChans[i] = 0;
            XUD_Sup_outct(c[i], token);
        }
    }
    for(int i = 0; i < nIn; i++)
    {
        if(epTypeTableIn[i] != XUD_EPTYPE_DIS && epStatFlagTableIn[i])
        {
            ep_info[i + USB_MAX_NUM_EP_OUT].resetting = 1;
            epChans[i + USB_MAX_NUM_EP_OUT] = 0;
            XUD_Sup_outct(c[i + USB_MAX_NUM_EP_OUT], token);
        }
    }
}

static void SendSpeed(XUD_chan c[], XUD_EpType epTypeTableOut[], XUD_EpType epTypeTableIn[], int nOut, int nIn, int speed)
{
    for(int i = 0; i < nOut; i++)
    {
        if(epTypeTableOut[i] != XUD_EPTYPE_DIS && epStatFlagTableOut[i])
        {
            XUD_Sup_outuint(c[i], speed);
        }
    }
    for(int i = 0; i < nIn; i++)
    {
        if(epTypeTableIn[i] != XUD_EPTYPE_DIS && epStatFlagTableIn[i])
        {
            XUD_Sup_outuint(c[i + USB_MAX_NUM_EP_OUT], speed);
        }
    }

}

// Main XUD loop
static int XUD_Manager_loop(XUD_chan epChans0[], XUD_chan epChans[],  chanend ?c_sof, XUD_EpType epTypeTableOut[], XUD_EpType epTypeTableIn[], int noEpOut, int noEpIn, XUD_PwrConfig pwrConfig)
{
    int reset = 1;            /* Flag for if device is returning from a reset */
    
    /* Make sure ports are on and reset port states */
    set_port_use_on(p_usb_clk);
    set_port_use_on(p_usb_txd);
    set_port_use_on(p_usb_rxd);
    set_port_use_on(flag0_port);
    set_port_use_on(flag1_port);
#if defined(__XS2A__)
    /* Extra flag port in XS2 */
    set_port_use_on(flag2_port);
#endif

#if defined(__XS3A__)
    
    #ifndef XUD_CORE_CLOCK
        #error XUD_CORE_CLOCK not defined (in MHz)
    #endif

    #ifdef XUD_SIM_XSIM
        #if (XUD_CORE_CLOCK >= 700)
            #define RX_RISE_DELAY 0
            #define RX_FALL_DELAY 0
            #define TX_RISE_DELAY 0
            #define TX_FALL_DELAY 7
        #elif (XUD_CORE_CLOCK >= 600)
            #define RX_RISE_DELAY 0
            #define RX_FALL_DELAY 0
            #define TX_RISE_DELAY 0
            #define TX_FALL_DELAY 5
        #else
            #error XUD_CORE_CLOCK must be >= 600
        #endif
    #else
        #if (XUD_CORE_CLOCK >= 600)
            #define RX_RISE_DELAY 1
            #define RX_FALL_DELAY 1
            #define TX_RISE_DELAY 1
            #define TX_FALL_DELAY 1
        #elif (XUD_CORE_CLOCK >= 500)
            #define RX_RISE_DELAY 1
            #define RX_FALL_DELAY 0
            #define TX_RISE_DELAY 1
            #define TX_FALL_DELAY 1
        #else
            #error XUD_CORE_CLOCK must be >= 500
        #endif
    #endif
#else
    #define RX_RISE_DELAY 5
    #define RX_FALL_DELAY 5
    #define TX_RISE_DELAY 5
    #define TX_FALL_DELAY 1
#endif
    
    // Handshaken ports need USB clock
    configure_clock_src(tx_usb_clk, p_usb_clk);
    configure_clock_src(rx_usb_clk, p_usb_clk);

    // This, along with the following delays,  forces the clock
    // to the ports to be effectively controlled by the
    // previous usb clock edges
    set_port_inv(p_usb_clk);
    set_port_sample_delay(p_usb_clk);

    // This delay controls the capture of rdy
    set_clock_rise_delay(tx_usb_clk, TX_RISE_DELAY);

    // This delay controls the launch of data.
    set_clock_fall_delay(tx_usb_clk, TX_FALL_DELAY);

    // This delay the capture of the rdyIn and data.
    set_clock_rise_delay(rx_usb_clk, RX_RISE_DELAY);
    set_clock_fall_delay(rx_usb_clk, RX_FALL_DELAY);

#ifdef __XS3A__
    set_pad_delay(flag1_port, 2);
#else
    set_pad_delay(flag1_port, 2);
#endif
        
    start_clock(tx_usb_clk);
    start_clock(rx_usb_clk);

 	configure_out_port_handshake(p_usb_txd, tx_readyin, tx_readyout, tx_usb_clk, 0);
  	configure_in_port_strobed_slave(p_usb_rxd, rx_rdy, rx_usb_clk);

    /* Clock RxA port from USB clock - helps fall event */
    configure_in_port(flag1_port, rx_usb_clk);

    unsigned noExit = 1;

    while(noExit)
    {
        unsigned settings[] = {0};
    
        /* Enable USB funcitonality in the device */
        XUD_HAL_EnableUsb(pwrConfig);
        
        while(1)
        {
            {
                /* Wait for VBUS before enabling pull-up. The USB Spec (page 150) allows 100ms
                 * between vbus valid and signalling attach */
                if(pwrConfig == XUD_PWR_SELF)
                {
                    while(1)
                    {
                        unsigned time;
                        timer t;

                        if(XUD_HAL_GetVBusState())
                        {
                            break;
                        }
                        t :> time;
                        time += (200 * REF_CLK_FREQ); // 200us poll
                        t when timerafter(time):> void;
                    }
                }
                
                /* Go into full speed mode: XcvrSelect and Term Select (and suspend) high */
                XUD_HAL_EnterMode_PeripheralFullSpeed();
 
                /* Setup flags for power signalling - i.e. J/K/SE0 line state*/
                XUD_HAL_Mode_Signalling();
                
                if (one)
                {
#if defined(XUD_BYPASS_CONNECT) 
                    reset = 1;
#else
                    reset = XUD_Init();
#endif
                    one = 0;
                }
                else
                {
                    timer t; unsigned time;
                    t :> time;
                    t when timerafter(time + SUSPEND_T_WTWRSTHS_ticks) :> int _;// T_WTRSTHS: 100-875us

                    /* Sample line state and check for reset (or suspend) */
                    XUD_LineState_t ls = XUD_HAL_GetLineState();
                    if(ls == XUD_LINESTATE_SE0)
                        reset = 1;
                    else
                        reset = 0;
                }
                /* Inspect for suspend or reset */
                if(!reset)
                {
                    /* Run user suspend code */
                    XUD_UserSuspend();

                    /* Run suspend code, returns 1 if reset from suspend, 0 for resume, -1 for invalid vbus */
                    reset = XUD_Suspend(pwrConfig);

                    if((pwrConfig == XUD_PWR_SELF) && (reset==-1))
                    {
                        /* Lost VBUS */
                        continue;
                    }

                    /* Run user resume code */
                    XUD_UserResume();
                }
                /* Test if coming back from reset or suspend */
                if(reset == 1)
                {
                    if(!sentReset)
                    {
                        SendResetToEps(epChans0, epChans, epTypeTableOut, epTypeTableIn, noEpOut, noEpIn, USB_RESET_TOKEN);
                        sentReset = 1;
                    }
                    
                    /* Reset the OUT ep structures */
                    for(int i = 0; i< noEpOut; i++)
                    {
#ifdef __XS3A__
                        ep_info[i].pid = USB_PIDn_DATA0;
#else
                        ep_info[i].pid = USB_PID_DATA0;
#endif
                    }

                    /* Reset in the ep structures */
                    for(int i = 0; i< noEpIn; i++)
                    {
                        ep_info[USB_MAX_NUM_EP_OUT+i].pid = USB_PIDn_DATA0;
                    }

                    /* Set default device address - note, for normal operation this is 0, but can be other values for testing */
                    XUD_HAL_SetDeviceAddress(XUD_STARTUP_ADDRESS);

#ifdef XUD_BYPASS_RESET
    #if defined(XUD_TEST_SPEED_HS)
                        g_curSpeed = XUD_SPEED_HS;
                        g_txHandshakeTimeout = HS_TX_HANDSHAKE_TIMEOUT;
                        XUD_HAL_EnterMode_PeripheralHighSpeed();
    #elif defined(XUD_TEST_SPEED_FS)
                        g_curSpeed = XUD_SPEED_FS;
                        g_txHandshakeTimeout = FS_TX_HANDSHAKE_TIMEOUT;
                        XUD_HAL_EnterMode_PeripheralFullSpeed(); //Technically not required since we should already be in FS mode..
    #else 
                        #error XUD_TEST_SPEED_ must be defined if using XUD_BYPASS_RESET!
    #endif
#else
                    if(g_desSpeed == XUD_SPEED_HS)
                    {
                        unsigned tmp = 0;
                        tmp = XUD_DeviceAttachHS(pwrConfig);

                        if(tmp == -1)
                        {
                            XUD_UserSuspend();
                            continue;
                        }
                        else if (!tmp)
                        {
                            /* HS handshake fail, mark as running in FS */
                            g_curSpeed = XUD_SPEED_FS;
                            g_txHandshakeTimeout = FS_TX_HANDSHAKE_TIMEOUT;
                        }
                        else
                        {
                            g_curSpeed = XUD_SPEED_HS;
                            g_txHandshakeTimeout = HS_TX_HANDSHAKE_TIMEOUT;
                        }
                    }
                    else
                    {
                        g_curSpeed = XUD_SPEED_FS;
                        g_txHandshakeTimeout = FS_TX_HANDSHAKE_TIMEOUT;
                    }
#endif

                    /* Send speed to EPs */
                    SendSpeed(epChans0, epTypeTableOut, epTypeTableIn, noEpOut, noEpIn, g_curSpeed);
                    sentReset=0;
                }
            }

            XUD_HAL_Mode_DataTransfer();

            set_thread_fast_mode_on();
            
            /* Run main IO loop */
            /* flag0: Rx Error
               flag1: Rx Active
               flag2: Null / Valid Token  */
            noExit = XUD_LLD_IoLoop(p_usb_rxd, flag1_port, p_usb_txd, flag0_port, flag2_port, epTypeTableOut, epTypeTableIn, epChans, noEpOut, c_sof);
            
            set_thread_fast_mode_off();
 
            if(!noExit)
                break;
        }
    }

    /* TODO stop clock blocks */

    /* Turn ports off */
    set_port_use_off(p_usb_txd);
    set_port_use_off(p_usb_rxd);
    set_port_use_off(flag0_port);
    set_port_use_off(flag1_port);
#ifdef __XS2A__
    set_port_use_off(flag2_port);
#endif
    set_port_use_off(p_usb_clk);
    return 0;
}

void _userTrapHandleRegister(void);

#pragma unsafe arrays
static void drain(chanend chans[], int n, int op, XUD_EpType epTypeTable[]) {
    for(int i = 0; i < n; i++) {
        if(epTypeTable[i] != XUD_EPTYPE_DIS) {
            switch(op) {
            case 0:
                outct(chans[i], XS1_CT_END);
                outuint(chans[i], XUD_SPEED_KILL);
                break;
            case 1:
                outct(chans[i], XS1_CT_END);
                while (!testct(chans[i]))
                    inuchar(chans[i]);
                chkct(chans[i], XS1_CT_END);
                break;
            }
        }
    }
}


#pragma unsafe arrays
int XUD_Main(chanend c_ep_out[], int noEpOut,
                chanend c_ep_in[], int noEpIn,
                chanend ?c_sof,
                XUD_EpType epTypeTableOut[], XUD_EpType epTypeTableIn[],
                XUD_BusSpeed_t speed, XUD_PwrConfig pwrConfig)
{
    /* Arrays for channels... */
    /* TODO use two arrays? */

    g_desSpeed = speed;

    for (int i=0; i < USB_MAX_NUM_EP;i++)
    {
        epChans[i] = 0;
    }

    for(int i = 0; i < USB_MAX_NUM_EP_OUT; i++)
    {
        ep_info[i].epAddress = i;
        ep_info[i].resetting = 0;
        ep_info[i].halted = USB_PIDn_NAK;
    }

    for(int i = 0; i < USB_MAX_NUM_EP_IN; i++)
    {
        ep_info[USB_MAX_NUM_EP_OUT+i].epAddress = (i | 0x80);
        ep_info[USB_MAX_NUM_EP_OUT+i].resetting = 0;
        ep_info[USB_MAX_NUM_EP_OUT+i].halted = 0;
    }

    /* Populate arrays of channels and status flag tabes */
    for(int i = 0; i < noEpOut; i++)
    {
      if(epTypeTableOut[i] != XUD_EPTYPE_DIS)
      {
        unsigned x;
        epChans0[i] = XUD_Sup_GetResourceId(c_ep_out[i]);

        asm("ldaw %0, %1[%2]":"=r"(x):"r"(epChans),"r"(i));
        ep_info[i].array_ptr = x;
        ep_info[i].saved_array_ptr = 0;

        asm("mov %0, %1":"=r"(x):"r"(c_ep_out[i]));
        ep_info[i].xud_chanend = x;

        asm("getd %0, res[%1]":"=r"(x):"r"(c_ep_out[i]));
        ep_info[i].client_chanend = x;

        asm("ldaw %0, %1[%2]":"=r"(x):"r"(ep_info),"r"(i*sizeof(XUD_ep_info)/sizeof(unsigned)));
        outuint(c_ep_out[i], x);
        ep_addr[i] = x;

        epStatFlagTableOut[i] = epTypeTableOut[i] & XUD_STATUS_ENABLE;
        epTypeTableOut[i] = epTypeTableOut[i] & 0x7FFFFFFF;

        ep_info[i].epType = epTypeTableOut[i];

#ifdef __XS3A__
        ep_info[i].pid = USB_PIDn_DATA0;
#else
        ep_info[i].pid = USB_PID_DATA0;
#endif
      }
    }

    for(int i = 0; i< noEpIn; i++)
    {
      if(epTypeTableIn[i] != XUD_EPTYPE_DIS)
      {
        int x;
        epChans0[i+USB_MAX_NUM_EP_OUT] = XUD_Sup_GetResourceId(c_ep_in[i]);

        asm("ldaw %0, %1[%2]":"=r"(x):"r"(epChans),"r"(USB_MAX_NUM_EP_OUT+i));
        ep_info[USB_MAX_NUM_EP_OUT+i].array_ptr = x;
        ep_info[USB_MAX_NUM_EP_OUT+i].saved_array_ptr = 0;

        asm("mov %0, %1":"=r"(x):"r"(c_ep_in[i]));
        ep_info[USB_MAX_NUM_EP_OUT+i].xud_chanend = x;

        asm("getd %0, res[%1]":"=r"(x):"r"(c_ep_in[i]));
        ep_info[USB_MAX_NUM_EP_OUT+i].client_chanend = x;

        asm("ldaw %0, %1[%2]":"=r"(x):"r"(ep_info),"r"((USB_MAX_NUM_EP_OUT+i)*sizeof(XUD_ep_info)/sizeof(unsigned)));

        outuint(c_ep_in[i], x);
        ep_addr[USB_MAX_NUM_EP_OUT+i] = x;

        ep_info[USB_MAX_NUM_EP_OUT+i].pid = USB_PIDn_DATA0;

        epStatFlagTableIn[i] = epTypeTableIn[i] & XUD_STATUS_ENABLE;
        epTypeTableIn[i] = epTypeTableIn[i] & 0x7FFFFFFF;

        ep_info[USB_MAX_NUM_EP_OUT+i].epType = epTypeTableIn[i];
      }
    }

    /* EpTypeTable Checks.  Note, currently this is not too crucial since we only really care if the EP is ISO or not */

    /* Check for control on IN/OUT 0 */
    if(epTypeTableOut[0] != XUD_EPTYPE_CTL || epTypeTableIn[0] != XUD_EPTYPE_CTL)
    {
        __builtin_trap();
    }

#if 0
    /* Check that if the required channel has a destination if the EP is marked as in use */
    for( int i = 0; i < noEpOut + noEpIn; i++ )
    {
        if( XUD_Sup_getd( epChans[i] )  == 0 && epTypeTableOut[i] != XUD_EPTYPE_DIS )
            XUD_Error_hex("XUD_Manager: OUT Ep marked as in use but chanend has no dest: ", i);
    }

    for( int i = 0; i < noEpOut + noEpIn; i++ )
    {
        if( XUD_Sup_getd( epChans[i + XUD_EP_COUNT ] )  == 0 && epTypeTableIn[i] != XUD_EPTYPE_DIS )
            XUD_Error_hex("XUD_Manager: IN Ep marked as in use but chanend has no dest: ", i);
    }
#endif

    /* Run the main XUD loop */
    XUD_Manager_loop(epChans0, epChans, c_sof, epTypeTableOut, epTypeTableIn, noEpOut, noEpIn, pwrConfig);

    // Need to close, drain, and check - three stages.
    for(int i = 0; i < 2; i++)
    {
        drain(c_ep_out, noEpOut, i, epTypeTableOut);  // On all inputs
        drain(c_ep_in, noEpIn, i, epTypeTableIn);     // On all output
    }

    return 0;
}

/* Legacy API support */
int XUD_Manager(chanend c_epOut[], int noEpOut,
                chanend c_epIn[], int noEpIn,
                NULLABLE_RESOURCE(chanend, c_sof),
                XUD_EpType epTypeTableOut[], XUD_EpType epTypeTableIn[],
                NULLABLE_RESOURCE(port, p_usb_rst),
                NULLABLE_RESOURCE(clock, clk),
                unsigned rstMask,
                XUD_BusSpeed_t desiredSpeed,
                XUD_PwrConfig pwrConfig)
{
    return XUD_Main(c_epOut, noEpOut, c_epIn, noEpIn, c_sof, epTypeTableOut, epTypeTableIn, desiredSpeed, pwrConfig);
}


