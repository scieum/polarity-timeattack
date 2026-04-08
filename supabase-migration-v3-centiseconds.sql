-- Convert existing time_seconds values from seconds to centiseconds (x100)
-- so old records display as "3.00초", "10.00초" etc.
-- Run this ONCE after deploying the centisecond timer change.

update quiz_rankings set time_seconds = time_seconds * 100;
