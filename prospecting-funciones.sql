-- Funciones independientes de Prospecting.
-- Ejecutar despues de prospecting-db.sql.

CREATE OR REPLACE FUNCTION fn_prioridad(p_score IN NUMBER) RETURN VARCHAR2
AS
    v_prioridad VARCHAR2(1);
BEGIN
    IF p_score >= 80 THEN
        v_prioridad := 'A';
    ELSIF p_score >= 60 THEN
        v_prioridad := 'B';
    ELSIF p_score >= 40 THEN
        v_prioridad := 'C';
    ELSE
        v_prioridad := 'D';   -- incluye score NULL
    END IF;

    RETURN v_prioridad;
END fn_prioridad;
/

CREATE OR REPLACE FUNCTION fn_calcular_score(p_id_empresa IN NUMBER) RETURN NUMBER
AS
    v_empresa  empresas%ROWTYPE;     -- una fila completa de EMPRESAS
    v_score    NUMBER := 0;
    v_cantidad NUMBER;
BEGIN
    SELECT * INTO v_empresa FROM empresas WHERE id_empresa = p_id_empresa;

    -- Puntos por tamano (si trabajadores es NULL no suma nada)
    IF v_empresa.trabajadores >= 200 THEN
        v_score := v_score + 30;
    ELSIF v_empresa.trabajadores >= 100 THEN
        v_score := v_score + 25;
    ELSIF v_empresa.trabajadores >= 50 THEN
        v_score := v_score + 20;
    ELSIF v_empresa.trabajadores >= 20 THEN
        v_score := v_score + 10;
    ELSIF v_empresa.trabajadores IS NOT NULL THEN
        v_score := v_score + 5;
    END IF;

    -- Puntos por tramo de ventas
    IF v_empresa.tramo_ventas LIKE 'Grande%' THEN
        v_score := v_score + 30;
    ELSIF v_empresa.tramo_ventas LIKE 'Mediana%' THEN
        v_score := v_score + 20;
    ELSIF v_empresa.tramo_ventas LIKE 'Peque%' THEN
        v_score := v_score + 10;
    END IF;

    -- Sitio web
    IF v_empresa.sitio_web IS NOT NULL THEN
        v_score := v_score + 10;
    END IF;

    -- Algun contacto con email
    SELECT COUNT(*) INTO v_cantidad
    FROM contactos
    WHERE id_empresa = p_id_empresa AND email IS NOT NULL;
    IF v_cantidad > 0 THEN
        v_score := v_score + 15;
    END IF;

    -- Algun contacto con linkedin
    SELECT COUNT(*) INTO v_cantidad
    FROM contactos
    WHERE id_empresa = p_id_empresa AND linkedin_url IS NOT NULL;
    IF v_cantidad > 0 THEN
        v_score := v_score + 10;
    END IF;

    -- Actividad economica registrada
    SELECT COUNT(*) INTO v_cantidad
    FROM empresa_actividad
    WHERE id_empresa = p_id_empresa;
    IF v_cantidad > 0 THEN
        v_score := v_score + 5;
    END IF;

    RETURN LEAST(v_score, 100);

EXCEPTION
    WHEN no_data_found THEN
        RAISE_APPLICATION_ERROR(-20010, 'La empresa ' || p_id_empresa || ' no existe.');
END fn_calcular_score;
/

CREATE OR REPLACE FUNCTION fn_valor_ponderado(p_id_empresa IN NUMBER) RETURN NUMBER
AS
    v_total NUMBER;
BEGIN
    SELECT NVL(SUM(valor_estimado * probabilidad / 100), 0)
    INTO v_total
    FROM oportunidades
    WHERE id_empresa = p_id_empresa
      AND etapa NOT IN ('GANADA', 'PERDIDA');

    RETURN v_total;
END fn_valor_ponderado;
/
