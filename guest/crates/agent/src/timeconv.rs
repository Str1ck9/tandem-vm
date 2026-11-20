//! Calendar conversion for setting the Windows clock (which takes broken-down UTC time).
#![cfg_attr(not(any(windows, test)), allow(dead_code))]

#[derive(Debug, PartialEq, Eq)]
pub struct CivilTime {
    pub year: i32, pub month: u32, pub day: u32, pub weekday: u32,
    pub hour: u32, pub minute: u32, pub second: u32,
}

/// Unix seconds to UTC civil time (proleptic Gregorian; Howard Hinnant's days-from-civil inverse).
pub fn civil_from_unix(secs: i64) -> CivilTime {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400) as u32;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = (yoe + era * 400 + if month <= 2 { 1 } else { 0 }) as i32;
    CivilTime {
        year, month, day,
        weekday: (days + 4).rem_euclid(7) as u32, // 1970-01-01 was a Thursday; 0 = Sunday
        hour: rem / 3600, minute: rem % 3600 / 60, second: rem % 60,
    }
}

/// Inverse of `civil_from_unix`: seconds since 1970-01-01 for a civil date and time.
pub fn unix_from_civil(year: i32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> i64 {
    let y = (if month <= 2 { year - 1 } else { year }) as i64;
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (month as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    (era * 146_097 + doe - 719_468) * 86_400 + hour as i64 * 3600 + minute as i64 * 60 + second as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(secs: i64) -> (i32, u32, u32, u32, u32, u32, u32) {
        let c = civil_from_unix(secs);
        (c.year, c.month, c.day, c.weekday, c.hour, c.minute, c.second)
    }

    #[test]
    fn known_instants() {
        assert_eq!(t(0), (1970, 1, 1, 4, 0, 0, 0));
        assert_eq!(t(951_782_400), (2000, 2, 29, 2, 0, 0, 0));          // leap day in a century leap year
        assert_eq!(t(1_709_251_199), (2024, 2, 29, 4, 23, 59, 59));     // last second of a leap day
        assert_eq!(t(1_709_251_200), (2024, 3, 1, 5, 0, 0, 0));
        assert_eq!(t(1_794_623_447), (2026, 11, 14, 6, 2, 30, 47));
        assert_eq!(t(4_102_444_800), (2100, 1, 1, 5, 0, 0, 0));         // 2100 is not a leap year
        assert_eq!(t(4_107_542_400), (2100, 3, 1, 1, 0, 0, 0));
        assert_eq!(t(-1), (1969, 12, 31, 3, 23, 59, 59));
    }

    #[test]
    fn civil_round_trip() {
        for secs in [0i64, -1, 951_782_400, 1_709_251_199, 1_794_623_447, 4_102_444_800, 4_107_542_400, -86_400 * 366] {
            let c = civil_from_unix(secs);
            assert_eq!(unix_from_civil(c.year, c.month, c.day, c.hour, c.minute, c.second), secs);
        }
    }
}
