//
//  Timer.swift
//  i41CV
//
//  Created by Miroslav Perovic on 8/28/14.
//  Copyright (c) 2014 iPera. All rights reserved.
//

// TimerSeected ==1 if TIMER=A, ==0 if TIMER=B
// Clock A is usually current time and B is usually stopwatch time (good until Dec 20, 2330)
// Alarm A is usually time of next alarm or cleared. B usually has a constant of 09999999999000h which is checked for timer integrity
// Scratch A is used to hold the last time when corrected.  B bit 5 is set for 24 hour, bit 6 is set for display of both time and date.
// Interval A,B - 56 bits total but only 20 are used: [4-0] sss.hh where sss = seconds, hh = hundredths
// Timer status - 13 bits
//   Bit  Meaning
//   0    ALMA  - Set on valid compare of Alarm A with Clock A
//   1    DTZA  - Set on overflow of clock A (or decrement of 10's complement)
//   2    ALMB  - Set on valid compare of Alarm B with Clock B
//   3    DTZB  - Set on overflow of Clock B
//   4    DTZIT - Set by terminal count state of Interval Timer (it has counted a whole interval)
//   5    PUS   - Power Up Status - set when power first applied or falls below a certain minimum
//   6    CKAEN - Enable Clock A incrementers
//   7    CKBEN - Enable Clock B incrementers
//   8    ALAEN - Enables comparator logic between Alarm A and Clock A - Set if Alarm A is enabled.  Since time alarms are usually enabled, this flag is usually set
//   9    ALBEN - Enables comparator logic between Alarm B and Clock B - Set if Alarm B is enabled.  Always clear since stopwatch alarms are not possible.  Timer alarms occur as a result of bit 3 set.
//  10    ITEN  - Enables Interval Timer incrementing and comparator logic (interval timer is running)
//  11    TESTA - Enables Test A mode
//  12    TESTB - Enables Test B mode
//
// This code does not do any accuracy factor corrections

import Foundation
import Cocoa

enum TimerType : Int {
	case TimerB = 0
	case TimerA = 1
}

struct TimerRegisters {
	var CLK: [Digits14] = [emptyDigit14, emptyDigit14]
	var ALM: [Digits14] = [emptyDigit14, emptyDigit14]
	var SCR: [Digits14] = [emptyDigit14, emptyDigit14]
	var INT: [Digits14] = [emptyDigit14, emptyDigit14]
	var ACC_F: Digits14 = emptyDigit14
	var TMR_S: Digits14 = emptyDigit14
}

class Timer : Peripheral {
	var timerSelected: TimerType = .TimerA
	var clock: [UInt64] = [0, 0]
	var alarm: [UInt] = [0, 0]
	var intTimer: UInt64 = 0
	var intTimerEnd: UInt64 = 0
	var cpu: CPU
	
	var registers: TimerRegisters = TimerRegisters()
	
	struct Static {
		static var token : dispatch_once_t = 0
		static var instance : Timer?
	}
	
	class var instance: Timer {
	dispatch_once(&Static.token) {  Static.instance = Timer() }
		return Static.instance!
	}
	
	init() {
		assert(Static.instance == nil, "Singleton already initialized!")

		cpu = CPU.sharedInstance
		bus!.installPeripheral(self, inSlot: 0xFB)
		
		resetTimer()
//		NSNotificationCenter.defaultCenter().addObserver(
//			self,
//			selector: Selector("applicationWillBecomeActive:"),
//			name: NSApplicationWillBecomeActiveNotification,
//			object: nil)

		NSNotificationCenter.defaultCenter().addObserverForName(
			NSApplicationWillBecomeActiveNotification,
			object: nil,
			queue: nil) { active in
				// This should help me detect when I'm being  activated.  I want to reset the clock
				if (Int(self.registers.TMR_S[1]) & 0x04) != 0 {		// bit 6 - Clock A enabled
					self.setToCurrentTime()
				}
		}
	}
	
	func resetTimer() {
		timerSelected = .TimerA
		registers.CLK[1] = emptyDigit14
		registers.CLK[0] = emptyDigit14
		registers.ALM[1] = emptyDigit14
		registers.ALM[0] = emptyDigit14
		registers.SCR[1] = emptyDigit14
		registers.SCR[0] = emptyDigit14
		registers.INT[1] = emptyDigit14
		registers.INT[0] = emptyDigit14
		registers.ACC_F = emptyDigit14
		registers.TMR_S = emptyDigit14
		
		// Clear internal simulation variable
		clock[TimerType.TimerA.rawValue] = 0
		clock[TimerType.TimerB.rawValue] = 0
		alarm[TimerType.TimerA.rawValue] = 0
		alarm[TimerType.TimerB.rawValue] = 0
		intTimer = 0
		intTimerEnd = 0
		
		// Set to initial timer module value
		registers.TMR_S[1] &= 0x04
		registers.ALM[0] = convertToReg14(9999999999000)		 // anti-corruption constant
		setToCurrentTime()
	}
	
	// Converts UINT64 to Reg14 (BCD)
	func convertToReg14(var src: UInt64) -> Digits14 {
		var result = emptyDigit14
		for idx in 0...13 {
			result[idx] = (Digit)(src % 10)
			src /= 10
		}
		
		return result
	}
	
	// Converts Reg14 (BCD) to UINT64
	func convertToUint64(reg: Digits14) -> UInt64 {
		var result: UInt64 = 0
//		for var idx = 13; idx >= 0; idx-- {
		for idx in reverse(13...0) {
			result *= 10
			result += UInt64(reg[idx]) % 10
		}
		
		return result
	}
	
	func setToCurrentTime() {
		let daylightSavingTimeOffset: Int = NSTimeZone.localTimeZone().daylightSavingTime ? 3600 : 0
		var dateComponents: NSDateComponents = NSDateComponents()
		dateComponents.day = 1
		dateComponents.month = 1
		dateComponents.year = 1900
		let referenceDate: NSDate = NSCalendar.currentCalendar().dateFromComponents(dateComponents)!
		let interval: NSTimeInterval = -1 * referenceDate.timeIntervalSinceNow + NSTimeInterval(daylightSavingTimeOffset)
		clock[TimerType.TimerA.rawValue] = UInt64(interval) * 1000
	}
	
	func applicationWillBecomeActive(sender : AnyObject) {
		// This should help me detect when I'm being  activated.  I want to reset the clock
		if (Int(registers.TMR_S[1]) & 0x04) != 0 {		// bit 6 - Clock A enabled
			setToCurrentTime()
		}
	}
	
	
	// MARK: Peripheral Delegate Methods
	func pluggedIntoBus(aBus: Bus) {
		bus = aBus
	}
	
	func readFromRegister(register: Bits4, inout into data: Digits14) {
		switch register {
		case 0x0:		// RTIME
			registers.CLK[timerSelected.rawValue] = convertToReg14(clock[timerSelected.rawValue])
			copyDigits(registers.CLK[timerSelected.rawValue], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
		case 0x1:		// RTIMEST
			registers.CLK[timerSelected.rawValue] = convertToReg14(clock[timerSelected.rawValue])
			copyDigits(registers.CLK[timerSelected.rawValue], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
		case 0x2:		// RALM
			copyDigits(registers.ALM[timerSelected.rawValue], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
		case 0x3:		// RSTS
			if timerSelected.rawValue != 0 {
				copyDigits(registers.TMR_S, sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
			} else {
				data = emptyDigit14
				for idx in 0..<4 {
					data[idx+1] = registers.ACC_F[idx]
				}
			}
		case 0x4:		// RSCR
			copyDigits(registers.SCR[timerSelected.rawValue], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
		case 0x5:		// RINT
			data = emptyDigit14
			for idx in 0..<5 {
				data[idx] = registers.INT[0][idx]
			}
		default:
			break
		}
	}
	
	func writeDataFrom(data: Digits14) {
		//TODO: Implement this method
	}
	
	func writeToRegister(register: Bits4, inout from data: Digits14) {
		// clearing flag 12,13 is in wrong place because SHIFT ON does not work.
		cpu.reg.FI &= 0xcfff			// clear flag 12, 13
		
		switch register {
		case 0x0:		// WTIME
			copyDigits(registers.CLK[timerSelected.rawValue], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
			clock[timerSelected.rawValue] = convertToUint64(registers.CLK[timerSelected.rawValue])
		case 0x1:		// WTIME-
			copyDigits(registers.CLK[timerSelected.rawValue], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
			clock[timerSelected.rawValue] = convertToUint64(registers.CLK[timerSelected.rawValue])
		case 0x2:		// WALM
			copyDigits(registers.ALM[timerSelected.rawValue], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
			clock[timerSelected.rawValue] = convertToUint64(registers.ALM[timerSelected.rawValue])
		case 0x3:		// WSTS
			if timerSelected == .TimerA {
				registers.TMR_S[0] &= data[0]
				registers.TMR_S[1] &= 0x0C | (data[1] & 0x03)
			} else {
				registers.ACC_F[3] = data[4] & 0x1;
				registers.ACC_F[2] = data[3];
				registers.ACC_F[1] = data[2];
				registers.ACC_F[0] = data[1];
			}
		case 0x4:		// WSCR
			copyDigits(registers.SCR[timerSelected.rawValue], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
		case 0x5:		// WINTST - set and start interval time
			copyDigits(registers.INT[0], sourceStartAt: 0, destination: &data, destinationStartAt: 0, count: 14)
			intTimerEnd = convertToUint64(registers.INT[0])
			intTimer = 0
			registers.TMR_S[2] |= 0x04			// set bit 10- ITEN - Interval Timer Enable
		case 0x7:		// STPINT - stop interval timer
			registers.TMR_S[2] &= 0x0B			// clear bit 10
		case 0x8:		// WKUPOFF - clear test mode
			if timerSelected == .TimerA {
				registers.TMR_S[2] &= 0x07		// clear bit 11 - Test A mode
			} else {
				registers.TMR_S[3] &= 0x0E		// clear bit 12 - Test B mode
			}
		case 0x9:		// WKUPON - set test mode
			if timerSelected == .TimerA {
				registers.TMR_S[2] |= 0x08		// set bit 11
			} else {
				registers.TMR_S[3] |= 0x01		// set bit 12
			}
		case 0xA:	// ALMOFF
			if timerSelected == .TimerA {
				registers.TMR_S[2] &= 0x0E		// clear bit 8
			} else {
				registers.TMR_S[2] &= 0x0D		// clear bit 9
			}
		case 0xB:	// ALMON
			if timerSelected == .TimerA {
				registers.TMR_S[2] |= 0x01		// set bit 8
			} else {
				registers.TMR_S[2] |= 0x02		// set bit 9
			}
		case 0xC:	// STOPC
			if timerSelected == .TimerA {		// should never stop Clock A or time will get messed up!
				registers.TMR_S[1] &= 0x0B		// clear bit 6 - Clock A incrementer
			} else {
				registers.TMR_S[1] &= 0x07		// clear bit 7 - Clock B incrementer
			}
		case 0xD:	// STARTC
			if timerSelected == .TimerA {
				registers.TMR_S[1] |= 0x04		// set bit 6
			} else {
				registers.TMR_S[1] |= 0x08		// set bit 7
			}
		case 0xE:	// TIMER=B
			timerSelected = .TimerB
		case 0xF:	// TIMER=A
			timerSelected = .TimerA
		default:
			break
		}
	}
}
