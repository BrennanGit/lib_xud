// Copyright 2011-2021 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
/** XUD_EpFuncs.S
  * @brief     ASM functions for data transfer to/from XUD
  * @author    Ross Owen, XMOS Limited
  */
#include "XUD_USB_Defines.h"
#include "XUD_AlignmentDefines.h"

#if defined __XS2A__
.set too_many_cores, main.maxcores > 6
.assert 0, too_many_cores, "Warning: More than 6 cores used on a tile. Ensure this is not the case on tile running XUD."
#endif

.section	.cp.rodata,"ac", @progbits
.cc_top ep_info_address.data,ep_info_address
.align FUNCTION_ALIGNMENT
.type	ep_info_address,@object
.size	ep_info_address, 4
ep_info_address:
.long	ep_info
.cc_bottom ep_info_address.data


//int XUD_GetSetupData(XUD_ep e_out, unsigned buffer[], unsigned &length);
//                     r0            r1                 r2
.text
.globl XUD_GetSetupData
.type XUD_GetSetupData, @function
.cc_top XUD_GetSetupData.func
.issue_mode single
.align FUNCTION_ALIGNMENT
XUD_GetSetupData:
    ENTSP_lu6   4
    stw         r4, sp[1]
    stw         r10, sp[2]

XUD_GetSetupData_:
    ldw        r4, r0[0]                        // Load mem address of EP in XUD ready table

    ldw        r11, r0[9]                       // Check if we missed a reset
    bt         r11, XUD_GetSetupData_Reset

    stw        r1, r0[3]                        // Store buffer in EP struct
    stw        r0, r4[0]                        // Mark ready
    ldw        r10, r0[2]                       // Load chanend for EP to use

XUD_GetSetupData_Retry:
    testct     r11, res[r10]                    // Test whether there is a RESET
    bt         r11, XUD_GetSetupData_Reset

XUD_GetSetupData_NoReq:                         // Entry for _NoReq
    in         r1, res[r10]                     // Input packet "word" length
    testct     r11, res[r10]                    // CT means we got a SETUP (not OUT).
    bf         r11, XUD_GetSetupData_GotOut
    inct       r11, res[r10]                    // Always get 0 (expect 8 bytes data)

//XUD_GetSetupData_CheckPid:
                                                // We expect data0 else something gone wrong...
                                                // TODO..

XUD_GetSetupData_ResetPid:                      // We must reset PID toggling on SETUP (both IN AND OUT)
#ifdef __XS3A__
    ldc         r11, USB_PIDn_DATA1
#else
    ldc         r11, USB_PID_DATA1
#endif
    stw         r11, r0[4]                      // Reset OUT toggle

    ldc         r11, 768                        // Assuming MAX_NUM_EPS is 16 and struct size is 44 here!
    add         r11, r0, r11

    ldc         r10, USB_PIDn_DATA1
    stw         r10, r11[4]                     // Reset IN toggle

    ldc         r0, 8                           // Return 8 byte length (TODO really could return actual length here)
    stw         r0, r2[0]

    ldc         r0, 0                           // Return no error XUD_RES_OKAY
    ldw         r10, sp[2]
    ldw         r4, sp[1]
    retsp       4

XUD_GetSetupData_GotOut:                        // Got an OUT instead not a SETUP
    int         r11, res[r10]

    shl         r3, r3, 2                       // Num received words to bytes
    add         r3, r11, r3                     // r11: Total bytes received (Note this includes 2 byte crc)

XUD_GetSetupData_CheckPid:
    ldw         r11, r0[6]                      // Load received PID from EP structure
    //shr         r11, r11, 24                    // Shift down due to inpw
    ldw         r10, r0[4]                      // Load expected PID

    xor         r11, r10, r11                   // Do the comparison
    bt          r11, XUD_GetSetupData_          // Ignore packet...

XUD_GetSetupData_PidOkay:
    ldw         r11, r0[5]                      // Load EP type
    bf          r11, XUD_GetSetupData_ReturnOk  // Jump over PID toggle for ISO

XUD_GetSetupData_PidToggle:
    ldc         r11, 8
    xor         r10, r10, r11
    stw         r10, r0[4]

XUD_GetSetupData_ReturnOk:
    sub         r0, r3, 2                       // Length correction for CRC correction (return val in r0)

    ldw         r10, sp[2]
    ldw         r4, sp[1]
    retsp       4

XUD_GetSetupData_Reset:
    mkmsk      r0, 32                           // Return -1 as length
    ldw         r10, sp[2]
    ldw         r4, sp[1]
    retsp      4

.size XUD_GetSetupData, .-XUD_GetSetupData
.cc_bottom XUD_GetSetupData.func
.globl XUD_GetSetupData.nstackwords
.globl XUD_GetSetupData.maxchanends
.globl XUD_GetSetupData.maxtimers
.globl XUD_GetSetupData.maxcores
.set XUD_GetSetupData.nstackwords, 4
.set XUD_GetSetupData.maxchanends, 0
.set XUD_GetSetupData.maxtimers, 0
.set XUD_GetSetupData.maxcores, 1
.globl XUD_GetSetupData.locnoside
.globl XUD_GetSetupData.locnochandec
.globl XUD_GetSetupData.locnoglobalaccess
.globl XUD_GetSetupData.locnointerfaceaccess
.globl XUD_GetSetupData.locnonotificationselect
.set XUD_GetSetupData.locnoside, 1
.set XUD_GetSetupData.locnochandec, 1
.set XUD_GetSetupData.locnoglobalaccess, 1
.set XUD_GetSetupData.locnointerfaceaccess, 1
.set XUD_GetSetupData.locnonotificationselect, 1

//void XUD_GetData_Select(chan c, XUD_ep ep, unsigned &datalength, XUD_Result_t &result);
//                        r0,     r1         r2                    r3
.globl XUD_GetData_Select
.type XUD_GetData_Select, @function
.cc_top XUD_GetData_Select.func
.align FUNCTION_ALIGNMENT
XUD_GetData_Select:
#if defined(__XS2A__) || defined(__XS3A__)
.issue_mode single
  ENTSP_lu6 0
#endif
    testct     r11, res[r0]
    bt         r11, XUD_GetData_Select_Return_Reset
    in         r11, res[r0]                     // Input packet "word" length
    int        r0, res[r0]                      // r0 is tail length (bytes)
	shr		   r0, r0, 3

XUD_GetData_Select_CalcdataLength:
    shl        r11, r11, 2                      // Num received words to bytes
    add        r0, r11, r0                      // r0: Total bytes received (Note this includes 2 byte crc)


XUD_GetData_CheckDataLength:
    sub         r0, r0, 2                       // Length correction for CRC correction
    ashr        r11, r0, 32                     // Check for < 0. No CRC check on ISO so less than 2 bytes could be received.
    bt          r11, XUD_GetData_Select_BadPkt
    stw         r0, r2[0]                       // Return length (note: passed by ref)

    ldw         r11, r1[5]                      // Load EP type
    bf          r11, XUD_GetData_Select_Return  // Jump over PID toggle and check for ISO


XUD_GetData_Select_CheckPid:                    // Check PID
    ldw         r11, r1[6]                      // Load received PID from EP structure
    //shr         r11, r11, 24                    // Shift off junk

                                                // Note: We can't just jump back to XUD_GetData_Select since other EP's might need service

    ldw         r0, r1[4]                       // Load expected PID
    xor         r11, r0, r11                    // Do the comparison
    bt          r11, XUD_GetData_Select_BadPkt

XUD_GetData_Select_PidToggle:
#ifdef __XS3A__
    ldc         r2, 0x88
#else
    ldc         r2, 8
#endif
    xor         r0, r0, r2
    stw         r0, r1[4]

XUD_GetData_Select_Return:
    stw         r11, r3[0]                      // Return RES_OKAY (note: passed by ref)
    retsp       0

XUD_GetData_Select_BadPkt:
    ldc         r0, 0                           // Return 0 length to be ultra safe and tidy..
    stw         r0, r2[0]                       // Return length (note: passed by ref)
    ldc         r0, 1
    stw         r0, r3[0]                       // Return RES_ERR (note: passed by ref)
    retsp       0

XUD_GetData_Select_Return_Reset:
    mkmsk       r0, 32                          // Return RST as result
    stw         r0, r3[0]
    ldc         r0, 0
    stw         r0, r2[0]                       // Just to be tidy, return 0 for length on reset
    retsp       0

.size XUD_GetData_Select, .-XUD_GetData_Select
.cc_bottom XUD_GetData_Select.func
.globl XUD_GetData_Select.nstackwords
.globl XUD_GetData_Select.maxchanends
.globl XUD_GetData_Select.maxtimers
.globl XUD_GetData_Select.maxcores
.set XUD_GetData_Select.nstackwords, 0
.set XUD_GetData_Select.maxchanends, 0
.set XUD_GetData_Select.maxtimers, 0
.set XUD_GetData_Select.maxcores, 1
.globl XUD_GetData_Select.locnoside
.globl XUD_GetData_Select.locnochandec
.globl XUD_GetData_Select.locnoglobalaccess
.globl XUD_GetData_Select.locnointerfaceaccess
.globl XUD_GetData_Select.locnonotificationselect
.set XUD_GetData_Select.locnoside, 1
.set XUD_GetData_Select.locnochandec, 1
.set XUD_GetData_Select.locnoglobalaccess, 1
.set XUD_GetData_Select.locnointerfaceaccess, 1
.set XUD_GetData_Select.locnonotificationselect, 1


//void XUD_SetData_Select(chan c, XUD_ep ep, XUD_Result_t &result);
//                        r0,     r1         r2
.globl XUD_SetData_Select
.type XUD_SetData_Select, @function
.cc_top XUD_SetData_Select.func
.align FUNCTION_ALIGNMENT
XUD_SetData_Select:
#if defined(__XS2A__) || defined(__XS3A__)
.issue_mode single
  ENTSP_lu6 0
#endif
    testct      r3, res[r0]
    bt          r3, XUD_SetData_Select_Reset

    in          r11, res[r0]                    // Data sent okay
    stw         r3, r2[0]                       // Store back in passed by ref-param. 0 For success.

XUD_SetData_Select_LoadEpType:
    ldw         r11, r1[5]                      // Don't do any toggling for ISO
    bf          r11, XUD_SetData_Select_DonePid

XUD_SetData_Select_PidToggle:
    ldw         r11, r1[4]                      // Load EP PID from structure
    ldc         r3, 0x88
    xor         r11, r11, r3
    stw         r11, r1[4]                      // Store back PID
XUD_SetData_Select_DonePid:
    retsp       0

XUD_SetData_Select_Reset:
    mkmsk       r0, 32                          // Return -1 as result
    stw         r0, r2[0]                       // Store back in passed by ref-param

                                                // Zero ready entry
    ldw         r2, r1[0]                       // Load mem address of EP in XUD ep table
    retsp       0
.size XUD_SetData_Select, .-XUD_SetData_Select
.cc_bottom XUD_SetData_Select.func
.globl XUD_SetData_Select.nstackwords
.globl XUD_SetData_Select.maxchanends
.globl XUD_SetData_Select.maxtimers
.globl XUD_SetData_Select.maxcores
.set XUD_SetData_Select.nstackwords, 0
.set XUD_SetData_Select.maxchanends, 0
.set XUD_SetData_Select.maxtimers, 0
.set XUD_SetData_Select.maxcores, 1
.globl XUD_SetData_Select.locnoside
.globl XUD_SetData_Select.locnochandec
.globl XUD_SetData_Select.locnoglobalaccess
.globl XUD_SetData_Select.locnointerfaceaccess
.globl XUD_SetData_Select.locnonotificationselect
.set XUD_SetData_Select.locnoside, 1
.set XUD_SetData_Select.locnochandec, 1
.set XUD_SetData_Select.locnoglobalaccess, 1
.set XUD_SetData_Select.locnointerfaceaccess, 1
.set XUD_SetData_Select.locnonotificationselect, 1


.globl XUD_ResetEpStateByAddr
.type XUD_ResetEpStateByAddr, @function

/* R0: ep number */
.cc_top XUD_ResetEpStateByAddr.func
.align FUNCTION_ALIGNMENT
XUD_ResetEpStateByAddr:
.issue_mode single
    ENTSP_lu6   0
    ldc         r1, 0x80
    and         r2, r0, r1
    bf          r2, XUD_ResetEpStateByAddr_OUT
    ldc         r1, USB_PIDn_DATA0
    bu          XUD_ResetEpStateByAddr_
XUD_ResetEpStateByAddr_OUT:
#if defined(__XS2A__) 
    ldc         r1, USB_PID_DATA0
#else
    ldc         r1, USB_PIDn_DATA0
#endif
XUD_ResetEpStateByAddr_:
    zext        r0, 7                           // Check for IN bit set
    bf          r2, NoOffset
    ldaw        r0, r0[4]                       // Assume MAX_NUM_EP_OUT is 16 here! (r0 = r0 + 4 * 4)
NoOffset:
    ldc         r2, 48                          // Size of XUD_ep_info struct TODO. FIXME!
    mul         r0, r0, r2
    ldw         r2, cp[ep_info_address]
    add         r0, r2, r0
    stw         r1, r0[4]
    retsp       0
.size XUD_ResetEpStateByAddr, .-XUD_ResetEpStateByAddr
.cc_bottom XUD_ResetEpStateByAddr.func
.globl XUD_ResetEpStateByAddr.nstackwords
.globl XUD_ResetEpStateByAddr.maxchanends
.globl XUD_ResetEpStateByAddr.maxtimers
.globl XUD_ResetEpStateByAddr.maxcores
.set XUD_ResetEpStateByAddr.nstackwords, 0
.set XUD_ResetEpStateByAddr.maxchanends, 0
.set XUD_ResetEpStateByAddr.maxtimers, 0
.set XUD_ResetEpStateByAddr.maxcores, 1
.globl XUD_ResetEpStateByAddr.locnoside
.globl XUD_ResetEpStateByAddr.locnochandec
.globl XUD_ResetEpStateByAddr.locnoglobalaccess
.globl XUD_ResetEpStateByAddr.locnointerfaceaccess
.globl XUD_ResetEpStateByAddr.locnonotificationselect
.set XUD_ResetEpStateByAddr.locnoside, 1
.set XUD_ResetEpStateByAddr.locnochandec, 1
.set XUD_ResetEpStateByAddr.locnoglobalaccess, 1
.set XUD_ResetEpStateByAddr.locnointerfaceaccess, 1
.set XUD_ResetEpStateByAddr.locnonotificationselect, 1


//void XUD_SetTestMode(XUD_ep ep, unsigned testMode);
.globl XUD_SetTestMode
.type XUD_SetTestMode, @function

.cc_top XUD_SetTestMode.func
.align FUNCTION_ALIGNMENT
XUD_SetTestMode:
#if defined(__XS2A__) || defined(__XS3A__)
.issue_mode single
    ENTSP_lu6 0
#endif
    ldw         r0, r0[2]                       // Load our chanend ID to use
    outct       res[r0], 1
    chkct       res[r0], 1
    out         res[r0], r1                     // Output test mode
    outct       res[r0], 1
    chkct       res[r0], 1
    retsp       0
.size XUD_SetTestMode, .-XUD_SetTestMode
.cc_bottom XUD_SetTestMode.func
.globl XUD_SetTestMode.nstackwords
.globl XUD_SetTestMode.maxchanends
.globl XUD_SetTestMode.maxtimers
.globl XUD_SetTestMode.maxcores
.set XUD_SetTestMode.nstackwords, 0
.set XUD_SetTestMode.maxchanends, 0
.set XUD_SetTestMode.maxtimers, 0
.set XUD_SetTestMode.maxcores, 1
.globl XUD_SetTestMode.locnoside
.globl XUD_SetTestMode.locnochandec
.globl XUD_SetTestMode.locnoglobalaccess
.globl XUD_SetTestMode.locnointerfaceaccess
.globl XUD_SetTestMode.locnonotificationselect
.set XUD_SetTestMode.locnoside, 1
.set XUD_SetTestMode.locnochandec, 1
.set XUD_SetTestMode.locnoglobalaccess, 1
.set XUD_SetTestMode.locnointerfaceaccess, 1
.set XUD_SetTestMode.locnonotificationselect, 1





