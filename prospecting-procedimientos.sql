-- Procedimientos independientes de Prospecting.
-- Requiere prospecting-db.sql y prospecting-funciones.sql.

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
