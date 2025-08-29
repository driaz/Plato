//
//  TextNormalizer.swift
//  Plato
//
//  Normalizes text for TTS by converting numbers, dates, currency, etc. to spoken form
//  This allows us to use the fast eleven_turbo_v2_5 model with good pronunciation
//

import Foundation

final class TextNormalizer {
    
    // MARK: - Main Entry Point
    
    /// Normalize text for TTS by converting numbers, dates, etc. to spoken form
    static func normalizeForTTS(_ text: String) -> String {
        var result = text
        
        // Order matters! Process more specific patterns first
        
        // 0. Handle special symbols first (before they're in other contexts)
        result = normalizeSymbols(result)
        
        // 1. Currency (before general numbers)
        result = normalizeCurrency(result)
        
        // 2. Percentages (before general numbers)
        result = normalizePercentages(result)
        
        // 3. Dates (before general numbers)
        result = normalizeDates(result)
        
        // 4. Temperature units  
        result = normalizeTemperatures(result)
        
        // 5. Times
        result = normalizeTimes(result)
        
        // 6. Stock tickers and market indices
        result = normalizeStockSymbols(result)
        
        // 7. Ordinals (1st, 2nd, 3rd, etc.)
        result = normalizeOrdinals(result)
        
        // 8. Decimal numbers (INCLUDING those with commas - do this BEFORE plain comma numbers)
        result = normalizeDecimals(result)
        
        // 9. Large numbers with commas (AFTER decimals so we don't interfere)
        result = normalizeCommaNumbers(result)
        
        // 10. Years (4-digit numbers that look like years)
        result = normalizeYears(result)
        
        // 11. Plain integers
        result = normalizePlainNumbers(result)
        
        // 12. Common abbreviations
        result = normalizeAbbreviations(result)
        
        return result
    }
    
    // MARK: - Symbols
    
    private static func normalizeSymbols(_ text: String) -> String {
        var result = text
        
        // Handle parentheses with + or - (like stock changes)
        result = result.replacingOccurrences(of: "(+", with: "(plus ")
        result = result.replacingOccurrences(of: "(-", with: "(minus ")
        
        // Handle other symbols
        let symbolReplacements = [
            " + ": " plus ",
            " - ": " minus ",
            " & ": " and ",
            "@": " at "
        ]
        
        for (symbol, replacement) in symbolReplacements {
            result = result.replacingOccurrences(of: symbol, with: replacement)
        }
        
        return result
    }
    
    // MARK: - Currency
    
    private static func normalizeCurrency(_ text: String) -> String {
        var result = text
        
        // Pattern: $XXX,XXX.XX
        let currencyPattern = #"\$(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)"#
        let regex = try! NSRegularExpression(pattern: currencyPattern)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        // Process matches in reverse to preserve indices
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let amountRange = Range(match.range(at: 1), in: result) else { continue }
            
            let amount = String(result[amountRange])
            let spokenAmount = speakCurrency(amount)
            result.replaceSubrange(range, with: spokenAmount)
        }
        
        return result
    }
    
    private static func speakCurrency(_ amount: String) -> String {
        let parts = amount.split(separator: ".")
        let dollars = String(parts[0]).replacingOccurrences(of: ",", with: "")
        
        var spoken = speakNumber(Int(dollars) ?? 0)
        spoken += (dollars == "1") ? " dollar" : " dollars"
        
        if parts.count > 1 {
            let cents = String(parts[1])
            if let centsNum = Int(cents), centsNum > 0 {
                spoken += " and " + speakNumber(centsNum)
                spoken += (cents == "01") ? " cent" : " cents"
            }
        }
        
        return spoken
    }
    
    // MARK: - Percentages
    
    private static func normalizePercentages(_ text: String) -> String {
        var result = text
        
        // Pattern: Handle both +XX.X% and -XX.X% and plain XX.X%
        let percentPattern = #"([+\-]?\d+(?:\.\d+)?)\s*%"#
        let regex = try! NSRegularExpression(pattern: percentPattern)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let numRange = Range(match.range(at: 1), in: result) else { continue }
            
            var number = String(result[numRange])
            var prefix = ""
            
            // Handle + or - prefix
            if number.hasPrefix("+") {
                prefix = "plus "
                number = String(number.dropFirst())
            } else if number.hasPrefix("-") {
                prefix = "minus "
                number = String(number.dropFirst())
            }
            
            let spoken = prefix + speakDecimal(number) + " percent"
            result.replaceSubrange(range, with: spoken)
        }
        
        return result
    }
    
    // MARK: - Dates
    
    private static func normalizeDates(_ text: String) -> String {
        var result = text
        
        // Pattern: Month DD, YYYY or Month DDth, YYYY
        let datePattern = #"(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})"#
        let regex = try! NSRegularExpression(pattern: datePattern, options: .caseInsensitive)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let monthRange = Range(match.range(at: 1), in: result),
                  let dayRange = Range(match.range(at: 2), in: result),
                  let yearRange = Range(match.range(at: 3), in: result) else { continue }
            
            let month = String(result[monthRange])
            let day = String(result[dayRange])
            let year = String(result[yearRange])
            
            let spokenDay = speakOrdinal(Int(day) ?? 0)
            let spokenYear = speakYear(year)
            
            let spoken = "\(month) \(spokenDay), \(spokenYear)"
            result.replaceSubrange(range, with: spoken)
        }
        
        // Pattern: MM/DD/YYYY or MM-DD-YYYY
        let numericDatePattern = #"(\d{1,2})[/-](\d{1,2})[/-](\d{4})"#
        let numericRegex = try! NSRegularExpression(pattern: numericDatePattern)
        let numericMatches = numericRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in numericMatches.reversed() {
            guard let range = Range(match.range, in: result),
                  let monthRange = Range(match.range(at: 1), in: result),
                  let dayRange = Range(match.range(at: 2), in: result),
                  let yearRange = Range(match.range(at: 3), in: result) else { continue }
            
            let monthNum = Int(result[monthRange]) ?? 0
            let day = Int(result[dayRange]) ?? 0
            let year = String(result[yearRange])
            
            let monthNames = ["", "January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]
            
            if monthNum > 0 && monthNum <= 12 {
                let spoken = "\(monthNames[monthNum]) \(speakOrdinal(day)), \(speakYear(year))"
                result.replaceSubrange(range, with: spoken)
            }
        }
        
        return result
    }
    
    // MARK: - Times
    
    private static func normalizeTimes(_ text: String) -> String {
        var result = text
        
        // Pattern: HH:MM AM/PM or HH:MM
        let timePattern = #"(\d{1,2}):(\d{2})\s*(AM|PM|am|pm)?"#
        let regex = try! NSRegularExpression(pattern: timePattern)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let hourRange = Range(match.range(at: 1), in: result),
                  let minuteRange = Range(match.range(at: 2), in: result) else { continue }
            
            let hour = Int(result[hourRange]) ?? 0
            let minute = Int(result[minuteRange]) ?? 0
            
            var spoken = ""
            
            // Handle special cases
            if minute == 0 {
                spoken = speakNumber(hour) + " o'clock"
            } else if minute == 15 {
                spoken = "quarter past " + speakNumber(hour)
            } else if minute == 30 {
                spoken = "half past " + speakNumber(hour)
            } else if minute == 45 {
                let nextHour = (hour % 12) + 1
                spoken = "quarter to " + speakNumber(nextHour)
            } else {
                spoken = speakNumber(hour)
                if minute < 10 {
                    spoken += " oh " + speakNumber(minute)
                } else {
                    spoken += " " + speakNumber(minute)
                }
            }
            
            // Add AM/PM if present
            if match.range(at: 3).location != NSNotFound,
               let ampmRange = Range(match.range(at: 3), in: result) {
                let ampm = result[ampmRange].lowercased()
                spoken += " " + (ampm == "am" ? "A M" : "P M")
            }
            
            result.replaceSubrange(range, with: spoken)
        }
        
        return result
    }
    
    // MARK: - Temperature Units
    
    private static func normalizeTemperatures(_ text: String) -> String {
        var result = text
        
        // First handle temperature ranges like "80s°F", "mid-70sF", "lower 90s C"
        // Pattern: optional prefix (lower/mid/upper/high/low) + number + s + optional degree symbol + unit
        let rangePattern = #"((?:lower|upper|mid|high|low)[\s-]?)?(\d{1,2}0)s\s*°?\s*([CF])\b"#
        let rangeRegex = try! NSRegularExpression(pattern: rangePattern, options: .caseInsensitive)
        let rangeMatches = rangeRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in rangeMatches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            
            var spoken = ""
            
            // Handle optional prefix (lower, mid, upper, etc.)
            if match.range(at: 1).location != NSNotFound,
               let prefixRange = Range(match.range(at: 1), in: result) {
                let prefix = String(result[prefixRange])
                    .replacingOccurrences(of: "-", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                spoken += prefix + " "
            }
            
            // Get the number part (e.g., "80" from "80s")
            if let numRange = Range(match.range(at: 2), in: result) {
                let number = String(result[numRange])
                spoken += number + "s"
            }
            
            // Check if degree symbol is present
            let hasDegreesSymbol = result[range].contains("°")
            
            // Get the unit (F or C)
            if let unitRange = Range(match.range(at: 3), in: result) {
                let unit = String(result[unitRange]).uppercased()
                let fullUnit = (unit == "F") ? "Fahrenheit" : "Celsius"
                
                // Add "degrees" only if the degree symbol was present
                if hasDegreesSymbol {
                    spoken += " degrees " + fullUnit
                } else {
                    spoken += " " + fullUnit
                }
            }
            
            result.replaceSubrange(range, with: spoken)
        }
        
        // Then handle single temperatures like "72°F", "72 °F", "72F", "72 F", "-5°C", "-5 °C", "-5C", "-5 C"
        let tempPattern = #"(-?\d+(?:\.\d+)?)\s*°?\s*([CF])\b"#
        let regex = try! NSRegularExpression(pattern: tempPattern, options: .caseInsensitive)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let numRange = Range(match.range(at: 1), in: result),
                  let unitRange = Range(match.range(at: 2), in: result) else { continue }
            
            let number = String(result[numRange])
            let unit = String(result[unitRange]).uppercased()
            
            let spokenNumber: String
            if number.contains(".") {
                spokenNumber = speakDecimal(number)
            } else if let num = Int(number) {
                spokenNumber = speakNumber(num)
            } else {
                spokenNumber = number
            }
            
            let fullUnit = (unit == "F") ? "Fahrenheit" : "Celsius"
            let spoken = "\(spokenNumber) degrees \(fullUnit)"
            
            result.replaceSubrange(range, with: spoken)
        }
        
        return result
    }
    
    // MARK: - Stock Symbols
    
    private static func normalizeStockSymbols(_ text: String) -> String {
        var result = text
        
        // Common market indices
        let replacements = [
            "S&P 500": "S and P five hundred",
            "S&P": "S and P",
            "NASDAQ": "nasdaq",
            "NYSE": "N Y S E",
            "FTSE": "footsie",
            "DAX": "dax",
            "CAC": "C A C",
            "DOW": "dow",
            "DJI": "D J I",
            "DJIA": "dow jones",
            "VIX": "vix"
        ]
        
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .caseInsensitive)
        }
        
        return result
    }
    
    // MARK: - Numbers
    
    private static func normalizeCommaNumbers(_ text: String) -> String {
        var result = text
        
        // Pattern: numbers with commas like 1,234 or 12,345,678 (but not decimals - those are handled separately)
        // This pattern specifically excludes numbers that have decimal points
        let commaPattern = #"\b(\d{1,3}(?:,\d{3})+)(?!\.\d)\b"#
        let regex = try! NSRegularExpression(pattern: commaPattern)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            
            let number = String(result[range]).replacingOccurrences(of: ",", with: "")
            if let num = Int(number) {
                let spoken = speakNumber(num)
                result.replaceSubrange(range, with: spoken)
            }
        }
        
        return result
    }
    
    private static func normalizeDecimals(_ text: String) -> String {
        var result = text
        
        // Pattern: decimal numbers including those with commas like 45,631.74
        let decimalPattern = #"\b(\d{1,3}(?:,\d{3})*\.\d+)\b"#
        let regex = try! NSRegularExpression(pattern: decimalPattern)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            
            let decimal = String(result[range])
            let spoken = speakDecimalWithCommas(decimal)
            result.replaceSubrange(range, with: spoken)
        }
        
        return result
    }
    
    private static func speakDecimalWithCommas(_ decimal: String) -> String {
        // Remove commas first
        let cleanDecimal = decimal.replacingOccurrences(of: ",", with: "")
        return speakDecimal(cleanDecimal)
    }
    
    private static func normalizeYears(_ text: String) -> String {
        var result = text
        
        // Pattern: 4-digit years between 1900-2099
        let yearPattern = #"\b(19\d{2}|20\d{2})\b"#
        let regex = try! NSRegularExpression(pattern: yearPattern)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            
            let year = String(result[range])
            let spoken = speakYear(year)
            result.replaceSubrange(range, with: spoken)
        }
        
        return result
    }
    
    private static func normalizePlainNumbers(_ text: String) -> String {
        var result = text
        
        // Pattern: plain numbers
        let numberPattern = #"\b(\d+)\b"#
        let regex = try! NSRegularExpression(pattern: numberPattern)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            
            let number = String(result[range])
            if let num = Int(number) {
                let spoken = speakNumber(num)
                result.replaceSubrange(range, with: spoken)
            }
        }
        
        return result
    }
    
    private static func normalizeOrdinals(_ text: String) -> String {
        var result = text
        
        // Pattern: 1st, 2nd, 3rd, 4th, etc.
        let ordinalPattern = #"\b(\d+)(st|nd|rd|th)\b"#
        let regex = try! NSRegularExpression(pattern: ordinalPattern, options: .caseInsensitive)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let numRange = Range(match.range(at: 1), in: result) else { continue }
            
            let number = String(result[numRange])
            if let num = Int(number) {
                let spoken = speakOrdinal(num)
                result.replaceSubrange(range, with: spoken)
            }
        }
        
        return result
    }
    
    // MARK: - Abbreviations
    
    private static func normalizeAbbreviations(_ text: String) -> String {
        var result = text
        
        let abbreviations = [
            "Mr.": "Mister",
            "Mrs.": "Missus",
            "Ms.": "Ms",
            "Dr.": "Doctor",
            "Prof.": "Professor",
            "St.": "Street",
            "Ave.": "Avenue",
            "Blvd.": "Boulevard",
            "Co.": "Company",
            "Corp.": "Corporation",
            "Inc.": "Incorporated",
            "Ltd.": "Limited",
            "vs.": "versus",
            "etc.": "et cetera",
            "i.e.": "that is",
            "e.g.": "for example",
            "CEO": "C E O",
            "CFO": "C F O",
            "CTO": "C T O",
            "AI": "A I",
            "ML": "M L",
            "API": "A P I",
            "US": "U S",  // Added
            "USA": "U S A",
            "UK": "U K",
            "EU": "E U",
            "UN": "U N",
            "GDP": "G D P",
            "IPO": "I P O",
            "ETF": "E T F",
            "FAQ": "F A Q",
            "HR": "H R",
            "IT": "I T",
            "PR": "P R",
            "FBI": "F B I",  // Added common ones
            "CIA": "C I A",
            "NASA": "NASA",  // NASA is often pronounced as a word
            "Q1": "Q one",
            "Q2": "Q two",
            "Q3": "Q three",
            "Q4": "Q four"
        ]
        
        for (abbr, expansion) in abbreviations {
            result = result.replacingOccurrences(of: abbr, with: expansion)
        }
        
        return result
    }
    
    // MARK: - Number Speaking Helpers
    
    private static func speakNumber(_ num: Int) -> String {
        if num == 0 { return "zero" }
        if num < 0 { return "negative " + speakNumber(-num) }
        
        let ones = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                     "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        
        if num < 10 {
            return ones[num]
        } else if num < 20 {
            return teens[num - 10]
        } else if num < 100 {
            let ten = num / 10
            let one = num % 10
            return tens[ten] + (one > 0 ? " " + ones[one] : "")
        } else if num < 1000 {
            let hundred = num / 100
            let remainder = num % 100
            return ones[hundred] + " hundred" + (remainder > 0 ? " " + speakNumber(remainder) : "")
        } else if num < 1_000_000 {
            let thousand = num / 1000
            let remainder = num % 1000
            
            // Special handling for clean thousands (e.g., 45,000)
            if remainder == 0 {
                return speakNumber(thousand) + " thousand"
            }
            // For numbers like 45,631 we need proper spacing
            return speakNumber(thousand) + " thousand " + speakNumber(remainder)
        } else if num < 1_000_000_000 {
            let million = num / 1_000_000
            let remainder = num % 1_000_000
            
            if remainder == 0 {
                return speakNumber(million) + " million"
            }
            return speakNumber(million) + " million " + speakNumber(remainder)
        } else {
            let billion = num / 1_000_000_000
            let remainder = num % 1_000_000_000
            
            if remainder == 0 {
                return speakNumber(billion) + " billion"
            }
            return speakNumber(billion) + " billion " + speakNumber(remainder)
        }
    }
    
    private static func speakOrdinal(_ num: Int) -> String {
        let specials = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
            11: "eleventh", 12: "twelfth", 13: "thirteenth", 14: "fourteenth",
            15: "fifteenth", 16: "sixteenth", 17: "seventeenth", 18: "eighteenth",
            19: "nineteenth", 20: "twentieth", 30: "thirtieth", 40: "fortieth",
            50: "fiftieth", 60: "sixtieth", 70: "seventieth", 80: "eightieth",
            90: "ninetieth"
        ]
        
        if let special = specials[num] {
            return special
        }
        
        if num < 100 {
            let ten = (num / 10) * 10
            let one = num % 10
            if one == 0 {
                return specials[ten] ?? speakNumber(num) + "th"
            } else {
                return speakNumber(ten) + " " + (specials[one] ?? speakNumber(one) + "th")
            }
        }
        
        // For larger numbers, just say "number" + "th"
        return speakNumber(num) + "th"
    }
    
    private static func speakDecimal(_ decimal: String) -> String {
        let parts = decimal.split(separator: ".")
        var result = speakNumber(Int(parts[0]) ?? 0)
        
        if parts.count > 1 {
            result += " point"
            for digit in parts[1] {
                if let d = Int(String(digit)) {
                    result += " " + speakNumber(d)
                }
            }
        }
        
        return result
    }
    
    private static func speakYear(_ year: String) -> String {
        guard year.count == 4, let yearNum = Int(year) else {
            return year
        }
        
        // Years 2000-2009
        if yearNum >= 2000 && yearNum <= 2009 {
            return "two thousand" + (yearNum > 2000 ? " " + speakNumber(yearNum - 2000) : "")
        }
        
        // Years 2010-2099
        if yearNum >= 2010 && yearNum <= 2099 {
            return "twenty " + speakNumber(yearNum - 2000)
        }
        
        // Years 1900-1999 and others: speak as two parts
        let firstTwo = yearNum / 100
        let lastTwo = yearNum % 100
        
        if lastTwo == 0 {
            return speakNumber(firstTwo) + " hundred"
        } else if lastTwo < 10 {
            return speakNumber(firstTwo) + " oh " + speakNumber(lastTwo)
        } else {
            return speakNumber(firstTwo) + " " + speakNumber(lastTwo)
        }
    }
}
