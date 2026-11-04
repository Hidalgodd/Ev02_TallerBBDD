-- Package pkg_crm de Prospecting.
-- Requiere prospecting-db.sql y prospecting-funciones.sql.

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
