-- ROCKY10-CALLTIME-GUARD-v1 layer 2: database triggers so call-time SETTINGS cannot be loosened.
-- Rule: a calling window may not start before 08:00 or end after 21:00. Per-day 0/0 means "use default"
-- and 2400/2400 means "closed" (ViciDial semantics) and are allowed. Enforced on campaign and list
-- call-time selection, on vicidial_call_times, vicidial_state_call_times and vicidial_call_time_holidays.
-- Campaign TEST1 (owner's own-number test campaign, MANUAL) is exempt. Idempotent: safe to re-run.
-- Campaign/list triggers check only when local_call_time CHANGES, so ViciDial's own frequent
-- UPDATEs (campaign_calldate, stats) are never affected.
-- Apply:  mysql asterisk < calltime_triggers.sql     (as DB root)
DELIMITER $$

DROP FUNCTION IF EXISTS rocky10_win_ok$$
CREATE FUNCTION rocky10_win_ok(s INT, e INT) RETURNS TINYINT DETERMINISTIC
BEGIN
  IF s IS NULL OR e IS NULL THEN RETURN 1; END IF;
  IF s = 0 AND e = 0 THEN RETURN 1; END IF;
  IF s = 2400 AND e = 2400 THEN RETURN 1; END IF;
  IF s >= 800 AND e <= 2100 AND s < e THEN RETURN 1; END IF;
  RETURN 0;
END$$

DROP FUNCTION IF EXISTS rocky10_default_ok$$
CREATE FUNCTION rocky10_default_ok(s INT, e INT) RETURNS TINYINT DETERMINISTIC
BEGIN
  IF s = 2400 AND e = 2400 THEN RETURN 1; END IF;
  IF s >= 800 AND e <= 2100 AND s < e THEN RETURN 1; END IF;
  RETURN 0;
END$$

-- '' if every referenced state rule is compliant, else a reason string.
DROP FUNCTION IF EXISTS rocky10_state_rules_reason$$
CREATE FUNCTION rocky10_state_rules_reason(lst TEXT) RETURNS VARCHAR(255) READS SQL DATA
BEGIN
  DECLARE n INT DEFAULT 0;
  DECLARE i INT DEFAULT 1;
  DECLARE rid VARCHAR(100);
  DECLARE ok TINYINT;
  DECLARE cnt INT;
  IF lst IS NULL OR LENGTH(lst) < 3 THEN RETURN ''; END IF;
  SET n = 1 + LENGTH(lst) - LENGTH(REPLACE(lst, '|', ''));
  WHILE i <= n DO
    SET rid = TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(lst, '|', i), '|', -1));
    IF LENGTH(rid) > 0 THEN
      SELECT COUNT(*) INTO cnt FROM vicidial_state_call_times WHERE state_call_time_id = rid;
      IF cnt > 0 THEN
        SELECT rocky10_default_ok(sct_default_start, sct_default_stop)
        AND rocky10_win_ok(sct_sunday_start, sct_sunday_stop) AND rocky10_win_ok(sct_monday_start, sct_monday_stop) AND rocky10_win_ok(sct_tuesday_start, sct_tuesday_stop) AND rocky10_win_ok(sct_wednesday_start, sct_wednesday_stop) AND rocky10_win_ok(sct_thursday_start, sct_thursday_stop) AND rocky10_win_ok(sct_friday_start, sct_friday_stop) AND rocky10_win_ok(sct_saturday_start, sct_saturday_stop)
          INTO ok FROM vicidial_state_call_times WHERE state_call_time_id = rid;
        IF ok = 0 THEN RETURN CONCAT('state call time ', rid, ' allows calling outside 08:00-21:00'); END IF;
      END IF;
    END IF;
    SET i = i + 1;
  END WHILE;
  RETURN '';
END$$

-- '' if the call_time_id exists and is compliant (incl. its state rules), else a reason.
DROP FUNCTION IF EXISTS rocky10_calltime_reason$$
CREATE FUNCTION rocky10_calltime_reason(p_id VARCHAR(10)) RETURNS VARCHAR(255) READS SQL DATA
BEGIN
  DECLARE cnt INT;
  DECLARE ok TINYINT;
  DECLARE lst TEXT;
  DECLARE r VARCHAR(255);
  SELECT COUNT(*) INTO cnt FROM vicidial_call_times WHERE call_time_id = p_id;
  IF cnt = 0 THEN RETURN CONCAT('call time ', p_id, ' does not exist'); END IF;
  SELECT rocky10_default_ok(ct_default_start, ct_default_stop)
    AND rocky10_win_ok(ct_sunday_start, ct_sunday_stop) AND rocky10_win_ok(ct_monday_start, ct_monday_stop) AND rocky10_win_ok(ct_tuesday_start, ct_tuesday_stop) AND rocky10_win_ok(ct_wednesday_start, ct_wednesday_stop) AND rocky10_win_ok(ct_thursday_start, ct_thursday_stop) AND rocky10_win_ok(ct_friday_start, ct_friday_stop) AND rocky10_win_ok(ct_saturday_start, ct_saturday_stop)
    , ct_state_call_times INTO ok, lst FROM vicidial_call_times WHERE call_time_id = p_id;
  IF ok = 0 THEN RETURN CONCAT('call time ', p_id, ' allows calling outside 08:00-21:00'); END IF;
  SET r = rocky10_state_rules_reason(lst);
  RETURN r;
END$$

-- ---- vicidial_call_times ----
DROP TRIGGER IF EXISTS rocky10_ct_bi$$
CREATE TRIGGER rocky10_ct_bi BEFORE INSERT ON vicidial_call_times FOR EACH ROW
BEGIN
  DECLARE r VARCHAR(255);
  IF NOT (rocky10_default_ok(NEW.ct_default_start, NEW.ct_default_stop) AND rocky10_win_ok(NEW.ct_sunday_start, NEW.ct_sunday_stop) AND rocky10_win_ok(NEW.ct_monday_start, NEW.ct_monday_stop) AND rocky10_win_ok(NEW.ct_tuesday_start, NEW.ct_tuesday_stop) AND rocky10_win_ok(NEW.ct_wednesday_start, NEW.ct_wednesday_stop) AND rocky10_win_ok(NEW.ct_thursday_start, NEW.ct_thursday_stop) AND rocky10_win_ok(NEW.ct_friday_start, NEW.ct_friday_stop) AND rocky10_win_ok(NEW.ct_saturday_start, NEW.ct_saturday_stop)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ROCKY10 CALL-TIME GUARD: call time may not allow calling before 08:00 or after 21:00';
  END IF;
  SET r = rocky10_state_rules_reason(NEW.ct_state_call_times);
  IF r <> '' THEN SET r = CONCAT('ROCKY10 CALL-TIME GUARD: ', r); SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = r; END IF;
END$$
DROP TRIGGER IF EXISTS rocky10_ct_bu$$
CREATE TRIGGER rocky10_ct_bu BEFORE UPDATE ON vicidial_call_times FOR EACH ROW
BEGIN
  DECLARE r VARCHAR(255);
  IF NOT (rocky10_default_ok(NEW.ct_default_start, NEW.ct_default_stop) AND rocky10_win_ok(NEW.ct_sunday_start, NEW.ct_sunday_stop) AND rocky10_win_ok(NEW.ct_monday_start, NEW.ct_monday_stop) AND rocky10_win_ok(NEW.ct_tuesday_start, NEW.ct_tuesday_stop) AND rocky10_win_ok(NEW.ct_wednesday_start, NEW.ct_wednesday_stop) AND rocky10_win_ok(NEW.ct_thursday_start, NEW.ct_thursday_stop) AND rocky10_win_ok(NEW.ct_friday_start, NEW.ct_friday_stop) AND rocky10_win_ok(NEW.ct_saturday_start, NEW.ct_saturday_stop)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ROCKY10 CALL-TIME GUARD: call time may not allow calling before 08:00 or after 21:00';
  END IF;
  SET r = rocky10_state_rules_reason(NEW.ct_state_call_times);
  IF r <> '' THEN SET r = CONCAT('ROCKY10 CALL-TIME GUARD: ', r); SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = r; END IF;
END$$

-- ---- vicidial_state_call_times ----
DROP TRIGGER IF EXISTS rocky10_sct_bi$$
CREATE TRIGGER rocky10_sct_bi BEFORE INSERT ON vicidial_state_call_times FOR EACH ROW
BEGIN
  IF NOT (rocky10_default_ok(NEW.sct_default_start, NEW.sct_default_stop) AND rocky10_win_ok(NEW.sct_sunday_start, NEW.sct_sunday_stop) AND rocky10_win_ok(NEW.sct_monday_start, NEW.sct_monday_stop) AND rocky10_win_ok(NEW.sct_tuesday_start, NEW.sct_tuesday_stop) AND rocky10_win_ok(NEW.sct_wednesday_start, NEW.sct_wednesday_stop) AND rocky10_win_ok(NEW.sct_thursday_start, NEW.sct_thursday_stop) AND rocky10_win_ok(NEW.sct_friday_start, NEW.sct_friday_stop) AND rocky10_win_ok(NEW.sct_saturday_start, NEW.sct_saturday_stop)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ROCKY10 CALL-TIME GUARD: state call time may not allow calling before 08:00 or after 21:00';
  END IF;
END$$
DROP TRIGGER IF EXISTS rocky10_sct_bu$$
CREATE TRIGGER rocky10_sct_bu BEFORE UPDATE ON vicidial_state_call_times FOR EACH ROW
BEGIN
  IF NOT (rocky10_default_ok(NEW.sct_default_start, NEW.sct_default_stop) AND rocky10_win_ok(NEW.sct_sunday_start, NEW.sct_sunday_stop) AND rocky10_win_ok(NEW.sct_monday_start, NEW.sct_monday_stop) AND rocky10_win_ok(NEW.sct_tuesday_start, NEW.sct_tuesday_stop) AND rocky10_win_ok(NEW.sct_wednesday_start, NEW.sct_wednesday_stop) AND rocky10_win_ok(NEW.sct_thursday_start, NEW.sct_thursday_stop) AND rocky10_win_ok(NEW.sct_friday_start, NEW.sct_friday_stop) AND rocky10_win_ok(NEW.sct_saturday_start, NEW.sct_saturday_stop)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ROCKY10 CALL-TIME GUARD: state call time may not allow calling before 08:00 or after 21:00';
  END IF;
END$$

-- ---- vicidial_call_time_holidays (0/0 = closed on that day, allowed) ----
DROP TRIGGER IF EXISTS rocky10_hol_bi$$
CREATE TRIGGER rocky10_hol_bi BEFORE INSERT ON vicidial_call_time_holidays FOR EACH ROW
BEGIN
  IF NOT rocky10_win_ok(NEW.ct_default_start, NEW.ct_default_stop) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ROCKY10 CALL-TIME GUARD: holiday call time may not allow calling before 08:00 or after 21:00';
  END IF;
END$$
DROP TRIGGER IF EXISTS rocky10_hol_bu$$
CREATE TRIGGER rocky10_hol_bu BEFORE UPDATE ON vicidial_call_time_holidays FOR EACH ROW
BEGIN
  IF NOT rocky10_win_ok(NEW.ct_default_start, NEW.ct_default_stop) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ROCKY10 CALL-TIME GUARD: holiday call time may not allow calling before 08:00 or after 21:00';
  END IF;
END$$

-- ---- vicidial_campaigns: validate the selected call time on INSERT and when it changes ----
DROP TRIGGER IF EXISTS rocky10_camp_bi$$
CREATE TRIGGER rocky10_camp_bi BEFORE INSERT ON vicidial_campaigns FOR EACH ROW
BEGIN
  DECLARE r VARCHAR(255);
  IF NEW.campaign_id <> 'TEST1' THEN
    SET r = rocky10_calltime_reason(NEW.local_call_time);
    IF r <> '' THEN SET r = CONCAT('ROCKY10 CALL-TIME GUARD: ', r); SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = r; END IF;
  END IF;
END$$
DROP TRIGGER IF EXISTS rocky10_camp_bu$$
CREATE TRIGGER rocky10_camp_bu BEFORE UPDATE ON vicidial_campaigns FOR EACH ROW
BEGIN
  DECLARE r VARCHAR(255);
  IF NEW.campaign_id <> 'TEST1' AND NOT (NEW.local_call_time <=> OLD.local_call_time) THEN
    SET r = rocky10_calltime_reason(NEW.local_call_time);
    IF r <> '' THEN SET r = CONCAT('ROCKY10 CALL-TIME GUARD: ', r); SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = r; END IF;
  END IF;
END$$

-- ---- vicidial_lists: a list may override the campaign call time ('campaign' = inherit) ----
DROP TRIGGER IF EXISTS rocky10_list_bi$$
CREATE TRIGGER rocky10_list_bi BEFORE INSERT ON vicidial_lists FOR EACH ROW
BEGIN
  DECLARE r VARCHAR(255);
  IF NEW.campaign_id <> 'TEST1' AND NEW.local_call_time IS NOT NULL AND NEW.local_call_time <> 'campaign' THEN
    SET r = rocky10_calltime_reason(NEW.local_call_time);
    IF r <> '' THEN SET r = CONCAT('ROCKY10 CALL-TIME GUARD: ', r); SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = r; END IF;
  END IF;
END$$
DROP TRIGGER IF EXISTS rocky10_list_bu$$
CREATE TRIGGER rocky10_list_bu BEFORE UPDATE ON vicidial_lists FOR EACH ROW
BEGIN
  DECLARE r VARCHAR(255);
  IF NEW.campaign_id <> 'TEST1' AND NEW.local_call_time IS NOT NULL AND NEW.local_call_time <> 'campaign'
     AND NOT (NEW.local_call_time <=> OLD.local_call_time) THEN
    SET r = rocky10_calltime_reason(NEW.local_call_time);
    IF r <> '' THEN SET r = CONCAT('ROCKY10 CALL-TIME GUARD: ', r); SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = r; END IF;
  END IF;
END$$

DELIMITER ;
