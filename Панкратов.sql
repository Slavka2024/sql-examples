SET search_path TO dbo, public;

-- ====================================================================
-- ОПИСАНИЕ АЛГОРИТМА:
-- 1. Безопасность при повторных запусках: функция не создаёт дубли и 
--    не накапливает ошибки, если её запустить дважды.
-- 2. Хронологический порядок: сначала гасятся самые старые долги, 
--    затем новые.
-- 3. Помесячное распределение: внутри месяца сумма делится 
--    пропорционально долгам по услугам.
-- 4. Точность: используется NUMERIC(19,4), погрешности округления 
--    компенсируются на последнем счёте.
-- 5. Параметры функции: типы данных (INT, SMALLINT) соответствуют требованиям задания.
-- ====================================================================

CREATE OR REPLACE FUNCTION dbo.ui_fp_payment_split(
    _link INT,
    _n_type SMALLINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_subscr        INT;
    v_amount        NUMERIC(19,4);
    v_remaining     NUMERIC(19,4);
    v_bill          RECORD;
    v_month_rec     RECORD;
    v_month_total   NUMERIC(19,4);
    v_month_budget  NUMERIC(19,4);
    v_pay_amount    NUMERIC(19,4);
    v_allocated     NUMERIC(19,4);
    v_last_bill_link INT;
BEGIN
    -- 1. Получаем параметры платежа
    SELECT f_subscr, n_amount INTO v_subscr, v_amount
    FROM dbo.fd_payments WHERE link = _link;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Платёж с link=% не найден', _link;
    END IF;

    v_remaining := v_amount;

    -- 2. Защита от дублирования: при повторном вызове функция сначала 
    --    возвращает ранее списанные суммы и очищает детали, чтобы 
    --    не создавать дубли и не накапливать ошибки
    UPDATE dbo.fd_bills b
    SET n_amount_rest = b.n_amount_rest + COALESCE(d.n_amount, 0)
    FROM dbo.fd_payment_details d
    WHERE d.f_payments = _link AND d.f_bills = b.link;

    DELETE FROM dbo.fd_payment_details WHERE f_payments = _link;

    -- 3. Распределение платежа
    IF _n_type = 0 THEN
        -- Тип 0: Хронологический порядок (сначала самые старые долги)
        FOR v_bill IN
            SELECT link, n_amount_rest, c_sale_items
            FROM dbo.fd_bills
            WHERE f_subscr = v_subscr AND n_amount_rest > 0
            ORDER BY d_date ASC
        LOOP
            RAISE NOTICE 'Обработка счета: link=%, сумма=%, услуга=%', 
                         v_bill.link, v_bill.n_amount_rest, v_bill.c_sale_items;
            EXIT WHEN v_remaining <= 0;
            v_pay_amount := LEAST(v_bill.n_amount_rest, v_remaining);
            INSERT INTO dbo.fd_payment_details (f_payments, f_bills, c_sale_items, n_amount)
            VALUES (_link, v_bill.link, v_bill.c_sale_items, v_pay_amount);
            v_remaining := v_remaining - v_pay_amount;
        END LOOP;

    ELSIF _n_type = 1 THEN
        -- Тип 1: Помесячно, внутри месяца пропорционально остаткам по услугам
        FOR v_month_rec IN
            SELECT DISTINCT DATE_TRUNC('month', d_date)::date AS month_start
            FROM dbo.fd_bills
            WHERE f_subscr = v_subscr AND n_amount_rest > 0
            ORDER BY month_start ASC
        LOOP
            RAISE NOTICE 'n_type=1: month_start=%, v_remaining=%, v_subscr=%',  
                         v_month_rec.month_start, v_remaining, v_subscr;
            EXIT WHEN v_remaining <= 0;

            SELECT COALESCE(SUM(n_amount_rest), 0) INTO v_month_total
            FROM dbo.fd_bills
            WHERE f_subscr = v_subscr
              AND n_amount_rest > 0
              AND DATE_TRUNC('month', d_date)::date = v_month_rec.month_start;

            IF v_month_total = 0 THEN CONTINUE; END IF;

            v_month_budget := LEAST(v_month_total, v_remaining);
            v_allocated := 0;
            v_last_bill_link := NULL;

            FOR v_bill IN
                SELECT link, n_amount_rest, c_sale_items
                FROM dbo.fd_bills
                WHERE f_subscr = v_subscr
                  AND n_amount_rest > 0
                  AND DATE_TRUNC('month', d_date)::date = v_month_rec.month_start
                ORDER BY link ASC
            LOOP
                RAISE NOTICE 'n_type=1: v_bill.n_amount_rest=%, v_remaining=%, v_month_total=%, v_month_budget=%', 
                         v_bill.n_amount_rest, v_remaining, v_month_total, v_month_budget;
                v_pay_amount := ROUND(v_bill.n_amount_rest / v_month_total * v_month_budget, 4);
		        --гарантирует, что списываемая сумма не превышает оставшуюся сумму платежа. 
				--Это защита от погрешностей округления, когда вычисленная доля счёта случайно 
				--оказалась больше остатка денег.
                v_pay_amount := LEAST(v_pay_amount, v_remaining);

                IF v_pay_amount > 0 THEN
                    INSERT INTO dbo.fd_payment_details (f_payments, f_bills, c_sale_items, n_amount)
                    VALUES (_link, v_bill.link, v_bill.c_sale_items, v_pay_amount);
                    v_allocated := v_allocated + v_pay_amount;
                    v_remaining := v_remaining - v_pay_amount;
                    v_last_bill_link := v_bill.link;
					
                    RAISE NOTICE 'n_type=1: v_allocated=%, v_remaining=%, v_pay_amount=%, v_last_bill_link=%', 
                         v_allocated, v_remaining, v_pay_amount, v_last_bill_link;
                END IF;
            END LOOP;

            -- Компенсация копеечной погрешности на последнем счёте месяца
            --  v_last_bill_link запоминает link последнего обработанного счёта в месяце. 
			-- Если после округления суммы по счетам не сходятся с бюджетом месяца, недостающие копейки 
			-- добавляются именно к этому счёту.			
            IF v_last_bill_link IS NOT NULL AND v_allocated <> v_month_budget AND v_remaining > 0 THEN
                v_pay_amount := LEAST(v_month_budget - v_allocated, v_remaining);
                IF v_pay_amount <> 0 THEN
                    UPDATE dbo.fd_payment_details 
                    SET n_amount = n_amount + v_pay_amount
                    WHERE f_payments = _link AND f_bills = v_last_bill_link;
                    v_remaining := v_remaining - v_pay_amount;
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- 4. Финальный пересчёт остатков
    -- Вычитаем сумму текущего платежа из ТЕКУЩЕГО остатка (n_amount_rest),
    -- а не из исходной суммы счёта (n_amount), чтобы сохранять историю предыдущих оплат.
    UPDATE dbo.fd_bills b
    SET n_amount_rest = b.n_amount_rest - COALESCE(p.paid_sum, 0)
    FROM (
        SELECT f_bills, SUM(n_amount) AS paid_sum
        FROM dbo.fd_payment_details
        WHERE f_payments = _link
        GROUP BY f_bills
    ) p
    WHERE b.link = p.f_bills;
END;
$$;


-- Проверка №1: два последовательных платежа
BEGIN TRANSACTION;

DO $$
DECLARE
    v_link INT;
BEGIN
    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-123', 1, '2019-01-05', 200)
    RETURNING link INTO v_link;
    PERFORM dbo.ui_fp_payment_split(v_link, 0::smallint);

    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-124', 1, '2019-01-05', 220)
    RETURNING link INTO v_link;
    PERFORM dbo.ui_fp_payment_split(v_link, 0::smallint);
END; $$;

SELECT * FROM dbo.fd_bills WHERE f_subscr = 1 ORDER BY d_date;
SELECT * FROM dbo.fd_payment_details ORDER BY f_payments, f_bills;

ROLLBACK;


-- Проверка №2: пропорционально, один платёж
BEGIN TRANSACTION;

DO $$
DECLARE
    v_link INT;
BEGIN
    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-123', 1, '2019-01-05', 200)
    RETURNING link INTO v_link;
    PERFORM dbo.ui_fp_payment_split(v_link, 1::smallint);
END; $$;

SELECT * FROM dbo.fd_bills WHERE f_subscr = 1 ORDER BY d_date;
SELECT * FROM dbo.fd_payment_details ORDER BY f_payments, f_bills;

ROLLBACK;


-- Проверка №3: пропорционально, два платежа
BEGIN TRANSACTION;

DO $$
DECLARE
    v_link INT;
BEGIN
    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-123', 1, '2019-01-05', 200)
    RETURNING link INTO v_link;
    PERFORM dbo.ui_fp_payment_split(v_link, 1::smallint);

    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-124', 1, '2019-01-05', 220)
    RETURNING link INTO v_link;
    PERFORM dbo.ui_fp_payment_split(v_link, 1::smallint);
END; $$;

SELECT * FROM dbo.fd_bills WHERE f_subscr = 1 ORDER BY d_date;
SELECT * FROM dbo.fd_payment_details ORDER BY f_payments, f_bills;

ROLLBACK;


-- Проверка №4: повторный вызов функции
BEGIN TRANSACTION;

DO $$
DECLARE
    v_link INT;
BEGIN
    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-123', 1, '2019-01-05', 200)
    RETURNING link INTO v_link;
    PERFORM dbo.ui_fp_payment_split(v_link, 1::smallint);
    PERFORM dbo.ui_fp_payment_split(v_link, 1::smallint);
END; $$;

SELECT 'ПРОВЕРКА №4: повторный вызов функции' as test_case;
SELECT * FROM dbo.fd_bills WHERE f_subscr = 1 ORDER BY d_date;
SELECT * FROM dbo.fd_payment_details ORDER BY f_payments, f_bills;

ROLLBACK;


-- ====================================================================
-- Дополнительные (Задание 2)
-- ====================================================================

-- Проверка №5: Частичная оплата месяца (пропорциональное распределение)
BEGIN TRANSACTION;

UPDATE dbo.fd_bills 
SET n_amount_rest = n_amount
WHERE f_subscr = 1 
  AND d_date >= '2019-02-01' 
  AND d_date < '2019-03-01';

DO $$
DECLARE
    v_link INT;
BEGIN
    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-TEST-05', 1, '2019-02-15', 150)
    RETURNING link INTO v_link;
    PERFORM dbo.ui_fp_payment_split(v_link, 1::smallint);
END; $$;

SELECT 'Проверка №5: Частичная оплата февраля (платёж 150, долг 330)' as test_case;

SELECT 
    d.c_sale_items,
    d.n_amount AS paid_amount,
    CASE d.c_sale_items
        WHEN 'ГВС' THEN 75
        WHEN 'ХВС' THEN 50
        WHEN 'Э/Э' THEN 25
    END AS expected_amount,
    CASE 
        WHEN d.n_amount = (CASE d.c_sale_items WHEN 'ГВС' THEN 75 WHEN 'ХВС' THEN 50 WHEN 'Э/Э' THEN 25 END) 
        THEN 'OK' 
        ELSE 'FAIL' 
    END as status
FROM dbo.fd_payment_details d
JOIN dbo.fd_payments p ON p.link = d.f_payments
WHERE p.c_number = 'П-TEST-05'
ORDER BY d.c_sale_items;

-- Автоматическая проверка результатов
DO $$
DECLARE
    v_sum NUMERIC(19,4);
    v_cnt INT;
BEGIN
    SELECT COALESCE(SUM(d.n_amount), 0), COUNT(*)
    INTO v_sum, v_cnt
    FROM dbo.fd_payment_details d
    JOIN dbo.fd_payments p ON p.link = d.f_payments
    WHERE p.c_number = 'П-TEST-05';

    IF v_cnt <> 3 OR v_sum <> 150.0000 THEN
        RAISE EXCEPTION 'Проверка №5 провалена: строк=%, сумма=% (ожидается 3 строки и 150.0000)', v_cnt, v_sum;
    END IF;
    RAISE NOTICE 'Проверка №5: Суммы сходятся верно (3 записи, сумма 150)';
END; $$;

ROLLBACK;


-- Проверка №6: Переплата на несколько месяцев (пропорциональное распределение)
BEGIN TRANSACTION;

UPDATE dbo.fd_bills 
SET n_amount_rest = n_amount
WHERE f_subscr = 1 
  AND d_date >= '2019-01-01' 
  AND d_date < '2019-04-01';

DO $$
DECLARE
    v_link INT;
BEGIN
    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-TEST-06', 1, '2019-03-15', 1000)
    RETURNING link INTO v_link;
    PERFORM dbo.ui_fp_payment_split(v_link, 1::smallint);
END; $$;

SELECT 'Проверка №6: Переплата на 3 месяца (платёж 1000, долг янв=330, фев=330, март=380)' as test_case;

SELECT 
    DATE_TRUNC('month', d_date)::date AS month,
    SUM(n_amount) AS total_debt,
    SUM(n_amount_rest) AS remaining_debt
FROM dbo.fd_bills 
WHERE f_subscr = 1 
  AND d_date >= '2019-01-01' 
  AND d_date < '2019-04-01'
GROUP BY DATE_TRUNC('month', d_date)
ORDER BY month;

SELECT 'Детали распределения' as info, d.c_sale_items, d.n_amount AS paid_amount
FROM dbo.fd_payment_details d
JOIN dbo.fd_payments p ON p.link = d.f_payments
WHERE p.c_number = 'П-TEST-06'
ORDER BY d.f_bills;

ROLLBACK;


-- Проверка №7: Повторный запуск функции (хронологический порядок) + автопроверка
BEGIN TRANSACTION;

UPDATE dbo.fd_bills 
SET n_amount_rest = n_amount
WHERE f_subscr = 1 
  AND d_date >= '2019-01-01' 
  AND d_date < '2019-03-01';

DO $$
DECLARE
    v_link INT;
BEGIN
    INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
    VALUES ('П-TEST-07', 1, '2019-02-15', 200)
    RETURNING link INTO v_link;

    -- Первый вызов
    PERFORM dbo.ui_fp_payment_split(v_link, 0::smallint);
    
    -- Второй вызов (имитация повторной обработки)
    PERFORM dbo.ui_fp_payment_split(v_link, 0::smallint);
END; $$;

SELECT 'Проверка №7: Повторный запуск функции (ожидается 2 записи, не 4)' as test_case;

SELECT 
    COUNT(*) AS actual_count,
    CASE WHEN COUNT(*) = 2 THEN 'OK' ELSE 'FAIL' END as status
FROM dbo.fd_payment_details d
JOIN dbo.fd_payments p ON p.link = d.f_payments
WHERE p.c_number = 'П-TEST-07';

-- Автоматическая проверка результатов
DO $$
DECLARE
    v_cnt INT;
    v_sum NUMERIC(19,4);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(d.n_amount), 0)
    INTO v_cnt, v_sum
    FROM dbo.fd_payment_details d
    JOIN dbo.fd_payments p ON p.link = d.f_payments
    WHERE p.c_number = 'П-TEST-07';

    IF v_cnt <> 2 OR v_sum <> 200.0000 THEN
        RAISE EXCEPTION 'Проверка №7 провалена: строк=%, сумма=% (ожидается 2 строки и 200.0000)', v_cnt, v_sum;
    END IF;
    RAISE NOTICE 'Проверка №7: Повторный запуск прошёл успешно (2 записи, сумма 200)';
END; $$;

ROLLBACK;