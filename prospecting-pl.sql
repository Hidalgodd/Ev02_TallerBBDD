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

 --Procedimientos
CREATE OR REPLACE PROCEDURE sp_registrar_empresa(
    p_rut              IN VARCHAR2,
    p_razon_social     IN VARCHAR2,
    p_nombre_comercial IN VARCHAR2,
    p_sitio_web        IN VARCHAR2,
    p_trabajadores     IN NUMBER,
    p_tramo_ventas     IN VARCHAR2,
    p_id_empresa       OUT NUMBER
) AS
    v_score empresas.score%TYPE;
BEGIN
    INSERT INTO empresas (rut, razon_social, nombre_comercial, sitio_web, trabajadores, tramo_ventas)
    VALUES (p_rut, p_razon_social, p_nombre_comercial, p_sitio_web, p_trabajadores, p_tramo_ventas)
    RETURNING id_empresa INTO p_id_empresa;       -- devuelve el id recien generado

    v_score := fn_calcular_score(p_id_empresa);

    UPDATE empresas
    SET score = v_score,
        prioridad = fn_prioridad(v_score)
    WHERE id_empresa = p_id_empresa;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Empresa registrada: ' || p_razon_social || ' (score ' || v_score || ')');

EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        RAISE_APPLICATION_ERROR(-20011, 'El RUT ' || p_rut || ' ya esta registrado.');
END sp_registrar_empresa;
/

-- Registrar un contacto
CREATE OR REPLACE PROCEDURE sp_registrar_contacto(
    p_id_empresa IN NUMBER,
    p_nombre     IN VARCHAR2,
    p_cargo      IN VARCHAR2,
    p_email      IN VARCHAR2,
    p_telefono   IN VARCHAR2,
    p_id_contacto OUT NUMBER
) AS
    e_empresa_inexistente EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_empresa_inexistente, -2291);  -- ORA-02291: parent key not found
BEGIN
    INSERT INTO contactos (id_empresa, nombre, cargo, email, telefono)
    VALUES (p_id_empresa, p_nombre, p_cargo, p_email, p_telefono)
    RETURNING id_contacto INTO p_id_contacto;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Contacto registrado: ' || p_nombre);

EXCEPTION
    WHEN e_empresa_inexistente THEN
        RAISE_APPLICATION_ERROR(-20010, 'La empresa ' || p_id_empresa || ' no existe.');
END sp_registrar_contacto;
/

-- 3.1 Normalizar datos de empresas (igual idea que trg_validar_datos_ciente del profe)
CREATE OR REPLACE TRIGGER trg_empresas_normalizar
BEFORE INSERT OR UPDATE ON empresas
FOR EACH ROW
BEGIN
    :NEW.rut          := UPPER(TRIM(:NEW.rut));
    :NEW.razon_social := TRIM(:NEW.razon_social);
    :NEW.sitio_web    := LOWER(TRIM(:NEW.sitio_web));
END trg_empresas_normalizar;
/

-- 3.2 Normalizar datos de contactos
CREATE OR REPLACE TRIGGER trg_contactos_normalizar
BEFORE INSERT OR UPDATE ON contactos
FOR EACH ROW
BEGIN
    :NEW.nombre := INITCAP(TRIM(:NEW.nombre));
    :NEW.email  := LOWER(TRIM(:NEW.email));
END trg_contactos_normalizar;
/

--Un solo contacto principal por empresa.
CREATE OR REPLACE TRIGGER trg_contacto_principal_unico
FOR INSERT OR UPDATE OF es_principal ON contactos
COMPOUND TRIGGER

    TYPE t_principal IS RECORD (
        id_empresa  contactos.id_empresa%TYPE,
        id_contacto contactos.id_contacto%TYPE
    );
    TYPE t_lista IS TABLE OF t_principal INDEX BY PLS_INTEGER;
    g_lista t_lista;

    AFTER EACH ROW IS
        v_pos PLS_INTEGER;
    BEGIN
        IF :NEW.es_principal = 1 THEN
            v_pos := g_lista.COUNT + 1;
            g_lista(v_pos).id_empresa  := :NEW.id_empresa;
            g_lista(v_pos).id_contacto := :NEW.id_contacto;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
    BEGIN
        FOR i IN 1 .. g_lista.COUNT LOOP
            UPDATE contactos
            SET es_principal = 0
            WHERE id_empresa = g_lista(i).id_empresa
              AND id_contacto <> g_lista(i).id_contacto
              AND es_principal = 1;
        END LOOP;
        g_lista.DELETE;
    END AFTER STATEMENT;

END trg_contacto_principal_unico;
/

-- No permitir interacciones con empresas marcadas NO_CONTACTAR
CREATE OR REPLACE TRIGGER trg_interaccion_no_contactar
BEFORE INSERT ON interacciones
FOR EACH ROW
DECLARE
    v_estado empresas.estado%TYPE;
BEGIN
    SELECT estado INTO v_estado FROM empresas WHERE id_empresa = :NEW.id_empresa;

    IF v_estado = 'NO_CONTACTAR' THEN
        RAISE_APPLICATION_ERROR(-20002, 'No se puede registrar la interaccion: la empresa esta en NO_CONTACTAR.');
    END IF;

EXCEPTION
    WHEN no_data_found THEN
        NULL;   -- empresa inexistente: que lo reclame la FK
END trg_interaccion_no_contactar;
/

-- Ajustar la probabilidad cuando la oportunidad se cierra
CREATE OR REPLACE TRIGGER trg_oportunidad_probabilidad
BEFORE INSERT OR UPDATE OF etapa ON oportunidades
FOR EACH ROW
BEGIN
    IF :NEW.etapa = 'GANADA' THEN
        :NEW.probabilidad := 100;
    ELSIF :NEW.etapa = 'PERDIDA' THEN
        :NEW.probabilidad := 0;
    END IF;
END trg_oportunidad_probabilidad;
/

-- Oportunidad GANADA -> la empresa pasa a CLIENTE
CREATE OR REPLACE TRIGGER trg_oportunidad_ganada
AFTER INSERT OR UPDATE OF etapa ON oportunidades
FOR EACH ROW
WHEN (NEW.etapa = 'GANADA')
BEGIN
    UPDATE empresas
    SET estado = 'CLIENTE'
    WHERE id_empresa = :NEW.id_empresa
      AND estado <> 'CLIENTE';
END trg_oportunidad_ganada;
/

--Auditoria de cambios de estado de la empresa
CREATE OR REPLACE TRIGGER trg_empresas_auditoria_estado
AFTER UPDATE OF estado ON empresas
FOR EACH ROW
WHEN (OLD.estado <> NEW.estado)
BEGIN
    INSERT INTO auditoria_estado_empresa (id_empresa, estado_anterior, estado_nuevo, usuario)
    VALUES (:OLD.id_empresa, :OLD.estado, :NEW.estado, USER);
END trg_empresas_auditoria_estado;
/

CREATE OR REPLACE PACKAGE pkg_crm
AS
    -- Variable publica: se mantiene durante toda la sesion
    g_interacciones_registradas NUMBER := 0;

    -- Excepcion publica asociada al error -20010 (empresa no existe)
    e_empresa_no_existe EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_empresa_no_existe, -20010);

    FUNCTION fn_oportunidades_abiertas(p_id_empresa IN NUMBER) RETURN NUMBER;

    PROCEDURE sp_registrar_interaccion(
        p_id_empresa       IN NUMBER,
        p_tipo             IN VARCHAR2,
        p_resultado        IN VARCHAR2,
        p_observaciones    IN CLOB,
        p_id_contacto      IN NUMBER    DEFAULT NULL,
        p_proximo_contacto IN TIMESTAMP DEFAULT NULL,
        p_id_interaccion   OUT NUMBER
    );

    PROCEDURE sp_cambiar_etapa_oportunidad(p_id_oportunidad IN NUMBER, p_nueva_etapa IN VARCHAR2);

    PROCEDURE sp_recalcular_scores;

    PROCEDURE sp_ficha_empresa(p_id_empresa IN NUMBER);

END pkg_crm;
/

-- BODY
CREATE OR REPLACE PACKAGE BODY pkg_crm
AS

    ------------------------------------------------------------------
    FUNCTION fn_oportunidades_abiertas(p_id_empresa IN NUMBER) RETURN NUMBER
    AS
        v_cantidad NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cantidad
        FROM oportunidades
        WHERE id_empresa = p_id_empresa
          AND etapa NOT IN ('GANADA', 'PERDIDA');

        RETURN v_cantidad;
    END fn_oportunidades_abiertas;

    ------------------------------------------------------------------
    PROCEDURE sp_registrar_interaccion(
        p_id_empresa       IN NUMBER,
        p_tipo             IN VARCHAR2,
        p_resultado        IN VARCHAR2,
        p_observaciones    IN CLOB,
        p_id_contacto      IN NUMBER    DEFAULT NULL,
        p_proximo_contacto IN TIMESTAMP DEFAULT NULL,
        p_id_interaccion   OUT NUMBER
    ) AS
        e_fk_inexistente EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_fk_inexistente, -2291);   -- empresa o contacto no existe
        e_tipo_invalido EXCEPTION;
        PRAGMA EXCEPTION_INIT(e_tipo_invalido, -2290);    -- viola el CHECK de tipo
    BEGIN
        -- Si la empresa es NO_CONTACTAR, el trigger trg_interaccion_no_contactar aborta aqui
        INSERT INTO interacciones (id_empresa, id_contacto, tipo, resultado, observaciones, proximo_contacto)
        VALUES (p_id_empresa, p_id_contacto, UPPER(p_tipo), p_resultado, p_observaciones, p_proximo_contacto)
        RETURNING id_interaccion INTO p_id_interaccion;

        -- Primera gestion: PENDIENTE pasa a CONTACTADO
        UPDATE empresas
        SET estado = 'CONTACTADO'
        WHERE id_empresa = p_id_empresa
          AND estado = 'PENDIENTE';

        g_interacciones_registradas := g_interacciones_registradas + 1;
        COMMIT;

    EXCEPTION
        WHEN e_fk_inexistente THEN
            RAISE_APPLICATION_ERROR(-20010, 'La empresa o el contacto indicado no existe.');
        WHEN e_tipo_invalido THEN
            RAISE_APPLICATION_ERROR(-20003, 'Tipo de interaccion invalido: ' || p_tipo);
    END sp_registrar_interaccion;

    ------------------------------------------------------------------
    PROCEDURE sp_cambiar_etapa_oportunidad(p_id_oportunidad IN NUMBER, p_nueva_etapa IN VARCHAR2)
    AS
        -- Dos VARRAY paralelos: la etapa en la posicion i tiene la probabilidad en la posicion i
        TYPE t_etapas IS VARRAY(6) OF VARCHAR2(30);
        TYPE t_probabilidades IS VARRAY(6) OF NUMBER;

        v_etapas t_etapas := t_etapas('PROSPECTO','CONTACTO','CALIFICADO','REUNION','PROPUESTA','NEGOCIACION');
        v_probs  t_probabilidades := t_probabilidades(10, 20, 35, 50, 65, 80);

        e_oportunidad_cerrada EXCEPTION;     -- excepcion personalizada (Semana 4)

        v_etapa_actual oportunidades.etapa%TYPE;
        v_nueva        oportunidades.etapa%TYPE := UPPER(p_nueva_etapa);
        v_prob         oportunidades.probabilidad%TYPE;
    BEGIN
        SELECT etapa INTO v_etapa_actual
        FROM oportunidades
        WHERE id_oportunidad = p_id_oportunidad;

        IF v_etapa_actual IN ('GANADA', 'PERDIDA') THEN
            RAISE e_oportunidad_cerrada;
        END IF;

        IF v_nueva = 'GANADA' THEN
            v_prob := 100;
        ELSIF v_nueva = 'PERDIDA' THEN
            v_prob := 0;
        ELSE
            FOR i IN 1 .. v_etapas.COUNT LOOP
                IF v_etapas(i) = v_nueva THEN
                    v_prob := v_probs(i);
                END IF;
            END LOOP;

            IF v_prob IS NULL THEN
                RAISE_APPLICATION_ERROR(-20022, 'Etapa invalida: ' || p_nueva_etapa);
            END IF;
        END IF;

        -- Si es GANADA, el trigger trg_oportunidad_ganada pasa la empresa a CLIENTE
        UPDATE oportunidades
        SET etapa = v_nueva,
            probabilidad = v_prob
        WHERE id_oportunidad = p_id_oportunidad;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Oportunidad ' || p_id_oportunidad || ': ' || v_etapa_actual || ' -> ' || v_nueva);

    EXCEPTION
        WHEN no_data_found THEN
            RAISE_APPLICATION_ERROR(-20020, 'La oportunidad ' || p_id_oportunidad || ' no existe.');
        WHEN e_oportunidad_cerrada THEN
            RAISE_APPLICATION_ERROR(-20021, 'La oportunidad ya esta cerrada (' || v_etapa_actual || ').');
    END sp_cambiar_etapa_oportunidad;

    ------------------------------------------------------------------
    PROCEDURE sp_recalcular_scores
    AS
        -- Cursor con parametro (Semana 3): recorre las empresas menos las del estado indicado
        CURSOR c_empresas(p_estado_excluido VARCHAR2) IS
            SELECT id_empresa, razon_social
            FROM empresas
            WHERE estado <> p_estado_excluido;

        v_score    NUMBER;
        v_contador NUMBER := 0;
    BEGIN
        FOR una_empresa IN c_empresas('NO_CONTACTAR') LOOP
            v_score := fn_calcular_score(una_empresa.id_empresa);

            UPDATE empresas
            SET score = v_score,
                prioridad = fn_prioridad(v_score)
            WHERE id_empresa = una_empresa.id_empresa;

            DBMS_OUTPUT.PUT_LINE(una_empresa.razon_social || ' -> score ' || v_score || ', prioridad ' || fn_prioridad(v_score));
            v_contador := v_contador + 1;
        END LOOP;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Empresas recalculadas: ' || v_contador);
    END sp_recalcular_scores;

    ------------------------------------------------------------------
    PROCEDURE sp_ficha_empresa(p_id_empresa IN NUMBER)
    AS
        -- RECORD con %TYPE (Semana 1)
        TYPE t_ficha IS RECORD (
            razon_social empresas.razon_social%TYPE,
            estado       empresas.estado%TYPE,
            trabajadores empresas.trabajadores%TYPE,
            score        empresas.score%TYPE,
            prioridad    empresas.prioridad%TYPE,
            comuna       ubicaciones.comuna%TYPE
        );
        v_ficha t_ficha;

        CURSOR c_contactos IS
            SELECT nombre, cargo, email
            FROM contactos
            WHERE id_empresa = p_id_empresa
            ORDER BY es_principal DESC, nombre;
    BEGIN
        SELECT e.razon_social, e.estado, e.trabajadores, e.score, e.prioridad, u.comuna
        INTO v_ficha.razon_social, v_ficha.estado, v_ficha.trabajadores,
             v_ficha.score, v_ficha.prioridad, v_ficha.comuna
        FROM empresas e
        LEFT JOIN ubicaciones u ON u.id_empresa = e.id_empresa AND u.es_principal = 1
        WHERE e.id_empresa = p_id_empresa;

        DBMS_OUTPUT.PUT_LINE('***** FICHA DE EMPRESA *****');
        DBMS_OUTPUT.PUT_LINE('Razon social: ' || v_ficha.razon_social);
        DBMS_OUTPUT.PUT_LINE('Comuna: ' || v_ficha.comuna);
        DBMS_OUTPUT.PUT_LINE('Estado: ' || v_ficha.estado);
        DBMS_OUTPUT.PUT_LINE('Trabajadores: ' || v_ficha.trabajadores);
        DBMS_OUTPUT.PUT_LINE('Score / Prioridad: ' || v_ficha.score || ' / ' || v_ficha.prioridad);
        DBMS_OUTPUT.PUT_LINE('Oportunidades abiertas: ' || fn_oportunidades_abiertas(p_id_empresa));
        DBMS_OUTPUT.PUT_LINE('Valor ponderado: ' || fn_valor_ponderado(p_id_empresa));
        DBMS_OUTPUT.PUT_LINE('--- Contactos ---');

        FOR un_contacto IN c_contactos LOOP
            DBMS_OUTPUT.PUT_LINE(un_contacto.nombre || ' | ' || un_contacto.cargo || ' | ' || un_contacto.email);
        END LOOP;

    EXCEPTION
        WHEN no_data_found THEN
            RAISE_APPLICATION_ERROR(-20010, 'La empresa ' || p_id_empresa || ' no existe.');
    END sp_ficha_empresa;

END pkg_crm;
/