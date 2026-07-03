Требуется написать функцию **dbo.ui_fp_payment_split**, которая по внесенным платежам в таблицу **dbo.fd_payments** будет расщеплять его на оплаты по конкретным счетам и услугам исходя из заполненных строк в таблице **dbo.fd_bills**. 
Функция так же должна пересчитывать остатки в таблице **dbo.fd_bills**.
Функция будет иметь два параметра, ид платежа и тип расщепления.
Тип расщепления может принимать значения:
0     – По дате, начиная с самых старых счетов.
1     – Пропорционально по каждой услуге в месяце. Сначала самый старый не оплаченный месяц, если он полностью оплачивается, следующий и так далее.
 Функция должна правильно отрабатывать при следующих проверках:

####  Проверка №1: 
```sql
BEGIN TRANSACTION;
    DO
    $$
    DECLARE
        _link     INT;
    BEGIN
        INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
        SELECT 'П-123', 1, '20190105', 200
        RETURNING link into _link;

        PERFORM dbo.ui_fp_payment_split (_link := _link, _n_type := 0::smallint);

        INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
        SELECT 'П-124', 1, '20190105', 220
        RETURNING link into _link;

        PERFORM dbo.ui_fp_payment_split (_link := _link, _n_type := 0::smallint);
    END;
    $$;

    SELECT * FROM dbo.fd_bills WHERE f_subscr = 1;
    SELECT * FROM dbo.fd_payment_details;
ROLLBACK;
```

#### Проверка №2:
```sql
/*------------------------------------------------------------------------------------
    Пропорционально один платежа
-------------------------------------------------------------------------------------*/
BEGIN TRANSACTION;
    DO
    $$
    DECLARE
        _link     INT;
    BEGIN
        INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
        SELECT 'П-123', 1, '20190105', 200
        RETURNING link into _link;

        PERFORM dbo.ui_fp_payment_split (_link := _link, _n_type := 1::smallint);
    END;
    $$;

    SELECT * FROM dbo.fd_bills WHERE f_subscr = 1;
    SELECT * FROM dbo.fd_payment_details;

ROLLBACK;
```

#### Проверка №3:
```sql
/*------------------------------------------------------------------------------------
    Пропорционально два платежа
-------------------------------------------------------------------------------------*/
BEGIN TRANSACTION;
    DO
    $$
    DECLARE
        _link     INT;
    BEGIN
        INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
        SELECT 'П-123', 1, '20190105', 200
        RETURNING link into _link;

        PERFORM dbo.ui_fp_payment_split (_link := _link, _n_type := 1::smallint);

        INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
        SELECT 'П-124', 1, '20190105', 220
        RETURNING link into _link;

        PERFORM dbo.ui_fp_payment_split (_link := _link, _n_type := 1::smallint);
    END;
    $$;

    SELECT * FROM dbo.fd_bills WHERE f_subscr = 1;
    SELECT * FROM dbo.fd_payment_details;   

ROLLBACK;
```

####  Проверка №4:
```sql

/*------------------------------------------------------------------------------------
    Один и тот же платеж 2 раза
-------------------------------------------------------------------------------------*/
BEGIN TRANSACTION;
    DO
    $$
    DECLARE
        _link     INT;
    BEGIN
        INSERT INTO dbo.fd_payments (c_number, f_subscr, d_date, n_amount)
        SELECT 'П-123', 1, '20190105', 200
        RETURNING link into _link;

        PERFORM dbo.ui_fp_payment_split (_link := _link, _n_type := 1::smallint);

        PERFORM dbo.ui_fp_payment_split (_link := _link, _n_type := 1::smallint);
    END;
    $$;

    SELECT * FROM dbo.fd_bills WHERE f_subscr = 1;
    SELECT * FROM dbo.fd_payment_details;

ROLLBACK;
```
### Задание 2 
Написать еще 3-и проверки, для функции **dbo.ui_fp_payment_split**. 

